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
    spawn
    adapter/http
    examples
)

# Build argument list from DOCS array, then generate intermediate binary format.
DOC_ARGS=()
for pkg in "${DOCS[@]}"; do
    DOC_ARGS+=("./${pkg}")
done
odin doc "${DOC_ARGS[@]}" -all-packages -doc-format -out:matryoshka-http-template.odin-doc

# Create config with absolute paths substituted
sed "s|PROJECT_ROOT|$ROOT_DIR|g" "$TOOLS_DIR/odin-doc.json" > "$APIDOCS_DIR/odin-doc.json"

cd "$APIDOCS_DIR"

# Render to HTML using the local odin-doc binary
if [ ! -f "$TOOLS_DIR/odin-doc" ]; then
    echo "Error: odin-doc binary not found in $TOOLS_DIR"
    echo "Run: bash kitchen/tools/get_odin_doc.sh"
    exit 1
fi

LD_LIBRARY_PATH="$TOOLS_DIR" "$TOOLS_DIR/odin-doc" "$ROOT_DIR/matryoshka-http-template.odin-doc" ./odin-doc.json

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
rm -f matryoshka-http-template.odin-doc
