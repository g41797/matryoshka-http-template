#!/usr/bin/env bash

set -ex

export LC_ALL=C.UTF-8
export LANG=C.UTF-8

TOOLS_DIR=$(realpath "$(dirname "$0")")
KITCHEN_DIR=$(realpath "$TOOLS_DIR/..")
ROOT_DIR=$(realpath "$KITCHEN_DIR/..")
APIDOCS_DIR="$KITCHEN_DIR/docs/apidocs"

cd "$ROOT_DIR"

rm -rf "$APIDOCS_DIR"
mkdir -p "$APIDOCS_DIR"

# Packages to document. Edit this list when adding or removing packages.
DOCS=(
    .
    pipeline
    handlers
    examples
    http_cs
)

# Create config with absolute paths substituted
sed "s|PROJECT_ROOT|$ROOT_DIR|g" "$TOOLS_DIR/odin-doc.json" > "$APIDOCS_DIR/odin-doc.json"

if [ ! -f "$TOOLS_DIR/odin-doc" ]; then
    echo "Error: odin-doc binary not found in $TOOLS_DIR"
    echo "Run: bash kitchen/tools/get_odin_doc.sh"
    exit 1
fi

# odin doc crashes when given multiple packages + collection flags (assertion in
# docs_writer.cpp: file_index_found != nullptr). Workaround: one .odin-doc per package
# with -all-packages (which includes transitive imports, satisfying the file_index
# requirement). Each package is rendered into an isolated temp directory, then the
# results are assembled and pkg-data.js is merged across all renders.
WORK_DIR=$(mktemp -d)
PKG_DATA_FILES=()

for pkg in "${DOCS[@]}"; do
    SAFE="${pkg//\//_}"
    DOC_FILE="$WORK_DIR/doc_${SAFE}.odin-doc"
    RENDER_DIR="$WORK_DIR/render_${SAFE}"
    mkdir -p "$RENDER_DIR"

    odin doc "./${pkg}" -all-packages -doc-format -out:"$DOC_FILE" \
        -collection:matryoshka="$ROOT_DIR/deps/matryoshka" \
        -collection:http="$ROOT_DIR/deps/odin-http"

    cp "$APIDOCS_DIR/odin-doc.json" "$RENDER_DIR/odin-doc.json"
    cd "$RENDER_DIR"
    LD_LIBRARY_PATH="$TOOLS_DIR" "$TOOLS_DIR/odin-doc" "$DOC_FILE" ./odin-doc.json
    PKG_DATA_FILES+=("$RENDER_DIR/pkg-data.js")
    rm -f "$DOC_FILE"
    cd "$ROOT_DIR"
done

# Root render provides shared assets and the collection landing page (README embed).
ROOT_RENDER="$WORK_DIR/render_."
cp "$ROOT_RENDER/index.html"   "$APIDOCS_DIR/"
cp "$ROOT_RENDER/style.css"    "$APIDOCS_DIR/"
cp "$ROOT_RENDER/search.js"    "$APIDOCS_DIR/"
cp "$ROOT_RENDER/favicon.svg"  "$APIDOCS_DIR/"
cp -r "$ROOT_RENDER/matryoshka-http-template/." "$APIDOCS_DIR/matryoshka-http-template/"

# Each sub-package render contributes only its own HTML subdirectory.
for pkg in pipeline handlers examples http_cs; do
    RENDER_DIR="$WORK_DIR/render_${pkg}"
    PKG_DIR="$RENDER_DIR/matryoshka-http-template/${pkg}"
    if [ -d "$PKG_DIR" ]; then
        mkdir -p "$APIDOCS_DIR/matryoshka-http-template/${pkg}"
        cp -r "$PKG_DIR/." "$APIDOCS_DIR/matryoshka-http-template/${pkg}/"
    fi
done

# Copy deps package HTML pages so that odin-doc's type cross-reference hrefs
# (e.g. deps/matryoshka/#PolyNode, deps/odin-http/#Server) resolve without
# 404. These pages are excluded from the sidebar and pkg-data.js search index
# but must exist on disk for the links in code examples to work.
# -n (no-clobber) gives us the union across renders without duplicate rewrites.
for pkg in pipeline handlers examples http_cs; do
    RENDER_DIR="$WORK_DIR/render_${pkg}"
    VENDOR_DIR="$RENDER_DIR/matryoshka-http-template/deps"
    if [ -d "$VENDOR_DIR" ]; then
        mkdir -p "$APIDOCS_DIR/matryoshka-http-template/deps"
        cp -rn "$VENDOR_DIR/." "$APIDOCS_DIR/matryoshka-http-template/deps/"
    fi
done

# Merge pkg-data.js entries from all per-package renders into one file.
#
# Each odin-doc render produces its own pkg-data.js listing only the packages in that
# render's .odin-doc (the documented package + all its transitive imports via -all-packages).
# We need a single pkg-data.js that lists every PROJECT package so that search.js can
# build the navigation sidebar correctly on every page.
#
# Implementation: the Python script is written on the fly into WORK_DIR, executed once,
# then removed with the rest of WORK_DIR. It is intentionally kept inline here (rather
# than as a permanent kitchen/tools/merge_pkg_data.py) because it exists solely to serve
# this script and has no other callers.
#
# What the script does:
#   - Reads every pkg-data.js file passed on argv
#   - Extracts the JSON packages object from each (format: var odin_pkg_data = {...};)
#   - Merges all package entries into one dict, deduplicating by package name
#   - Drops entries whose "path" contains "/deps/" (deps deps pulled in by -all-packages)
#   - Writes the merged result preserving the odin-doc generation header comment
cat > "$WORK_DIR/merge_pkgs.py" << 'PYEOF'
import re, sys, json
all_pkgs = {}
header = ""
for fname in sys.argv[1:]:
    content = open(fname).read()
    if not header:
        header = content.split('\n')[0]
    m = re.search(r'var odin_pkg_data = (\{.*\});', content, re.DOTALL)
    if m:
        for name, pkg in json.loads(m.group(1)).get("packages", {}).items():
            if "/deps/" not in pkg.get("path", ""):
                all_pkgs[name] = pkg
print(header)
print("var odin_pkg_data = " + json.dumps({"packages": all_pkgs}, indent="\t") + ";")
PYEOF
python3 "$WORK_DIR/merge_pkgs.py" "${PKG_DATA_FILES[@]}" > "$APIDOCS_DIR/pkg-data.js"

rm -rf "$WORK_DIR"

cd "$APIDOCS_DIR"

# Post-process: remove "Generation Information" sections and TOC links
find . -name "index.html" -exec sed -i '/<h2 id="pkg-generation-information">/,/<p>Generated with .*<\/p>/d' {} +
find . -name "index.html" -exec sed -i '/<li><a href="#pkg-generation-information">/d' {} +

# Post-process: Make all links and assets relative.
# odin-doc emits absolute hrefs ("/matryoshka-http-template/...")
# Depth 0 — root index.html
sed -i 's|href="/\([^/]\)|href="./\1|g' index.html
sed -i 's|src="/\([^/]\)|src="./\1|g' index.html

# All other index.html files: compute depth by counting path separators
find . -name "index.html" ! -path "./index.html" | while read -r f; do
    depth=$(echo "$f" | tr -cd '/' | wc -c)
    actual_depth=$(( depth - 1 ))
    prefix=""
    for _ in $(seq 1 "$actual_depth"); do
        prefix="../$prefix"
    done
    sed -i "s|href=\"/\([^/]\)|href=\"${prefix}\1|g" "$f"
    sed -i "s|src=\"/\([^/]\)|src=\"${prefix}\1|g" "$f"
done

# Fix blank root package nav link
find . -name "index.html" -exec sed -i \
    's|<a \([^>]*\)href="\([^"]*\)matryoshka-http-template/"\([^>]*\)></a>|<a \1href="\2matryoshka-http-template/"\3>matryoshka-http-template</a>|g' {} +

# pkg-data.js contains absolute paths used by search.js for navigation
sed -i 's|"path": "/|"path": "/apidocs/|g' "$APIDOCS_DIR/pkg-data.js"

# Simplify links in the root package index.html
if [ -f "matryoshka-http-template/index.html" ]; then
    sed -i 's|href="\.\./matryoshka-http-template/|href="./|g' matryoshka-http-template/index.html
fi

# Rebuild every sidebar <ul> so it lists all project packages.
#
# odin-doc generates static sidebar HTML per-render; each page only lists the
# packages present in that render's .odin-doc (the documented package plus its
# transitive imports via -all-packages). After multi-pass rendering the sidebar
# on each page is incomplete — e.g. matryoshka-http-template/index.html shows
# only the root package, pipeline/index.html shows only pipeline + deps.
#
# Fix: read the merged pkg-data.js (which now lists all project packages) and
# rewrite the <ul> inside <nav id="pkg-sidebar"> on every page to include all
# project packages with correct relative hrefs and the current page marked active.
# Passed via stdin heredoc (same inline-only design as merge_pkgs.py above:
# single caller, no permanent helper file).
python3 - "$APIDOCS_DIR/pkg-data.js" \
    "$APIDOCS_DIR/matryoshka-http-template/index.html" \
    "$APIDOCS_DIR/matryoshka-http-template"/*/index.html << 'PYEOF'
import re, sys, json, os

pkg_js = open(sys.argv[1]).read()
m = re.search(r'var odin_pkg_data = (\{.*\});', pkg_js, re.DOTALL)
packages = json.loads(m.group(1))["packages"]

# Build ordered list: (display_name, sub_dir, rel_path)
# path in pkg-data.js is "/apidocs/matryoshka-http-template/pipeline" etc.
pkgs = []
for _, info in packages.items():
    path = re.sub(r'^/apidocs/', '', info["path"]).rstrip("/")
    sub_dir = path.split("/", 1)[1] if "/" in path else ""
    display = path.split("/")[-1]   # directory name matches odin-doc link text convention
    pkgs.append((display, sub_dir, path))

for html_file in sys.argv[2:]:
    content = open(html_file).read()
    if 'id="pkg-sidebar"' not in content:
        continue

    # Determine link prefix by inspecting how deep the file sits under apidocs
    file_dir = os.path.dirname(html_file)
    dir_name = os.path.basename(file_dir)
    parent   = os.path.basename(os.path.dirname(file_dir))

    if parent == "matryoshka-http-template":      # depth-2: sub-package page
        link_prefix = "../../matryoshka-http-template/"
        file_rel    = "matryoshka-http-template/" + dir_name
    elif dir_name == "matryoshka-http-template":  # depth-1: collection landing page
        link_prefix = "./"
        file_rel    = "matryoshka-http-template"
    else:
        continue

    items = []
    for display, sub_dir, pkg_path in pkgs:
        href        = link_prefix + sub_dir if sub_dir else link_prefix
        active_attr = ' class="active"' if pkg_path == file_rel else ''
        items.append(f'<li class="nav-item"><a{active_attr} href="{href}">{display}</a></li>')

    new_ul = "<ul>\n" + "\n".join(items) + "\n</ul>"

    nav_m = re.search(r'(<nav id="pkg-sidebar"[^>]*>)(.*?)(</nav>)', content, re.DOTALL)
    if not nav_m:
        continue
    nav_inner = nav_m.group(2)
    ul_pos = nav_inner.find("<ul>")
    if ul_pos == -1:
        continue

    # Walk nav inner with a nesting counter to find the outer </ul>
    # (deps entries have nested <ul> inside the sidebar outer <ul>)
    nest, pos, ul_end = 0, ul_pos, -1
    while pos < len(nav_inner):
        if nav_inner[pos:pos+4] == "<ul>":
            nest += 1; pos += 4
        elif nav_inner[pos:pos+5] == "</ul>":
            nest -= 1
            if nest == 0:
                ul_end = pos + 5; break
            pos += 5
        else:
            pos += 1

    if ul_end == -1:
        continue

    new_nav = nav_m.group(1) + nav_inner[:ul_pos] + new_ul + "\n" + nav_inner[ul_end:] + nav_m.group(3)
    content = content[:nav_m.start()] + new_nav + content[nav_m.end():]
    open(html_file, "w").write(content)
PYEOF

# Copy shared assets into every package subdirectory so the browser finds
# them regardless of which relative path a cached HTML page requests them from.
find . -mindepth 2 -name "index.html" | while read -r f; do
    dir=$(dirname "$f")
    cp favicon.svg  "$dir/favicon.svg"
    cp style.css    "$dir/style.css"
    cp pkg-data.js  "$dir/pkg-data.js"
    cp search.js    "$dir/search.js"
done

# Cache-busting
VER=$(date +%Y%m%d%H%M%S)
find . -name "index.html" -exec sed -i \
    -e "s|favicon\.svg\"|favicon.svg?v=${VER}\"|g" \
    -e "s|style\.css\"|style.css?v=${VER}\"|g" \
    -e "s|pkg-data\.js\"|pkg-data.js?v=${VER}\"|g" \
    -e "s|search\.js\"|search.js?v=${VER}\"|g" {} +

cd "$ROOT_DIR"
