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

# Generate odin-doc for all template packages.
odin doc . \
    ./pipeline \
    ./spawn \
    ./adapter/http \
    ./examples \
    -all-packages -doc-format -out:matryoshka-http-template.odin-doc

# Render to HTML using the odin-doc tool from vendor/matryoshka.
# If a local odin-doc binary is not present, skip HTML rendering.
ODIN_DOC="$ROOT_DIR/vendor/matryoshka/kitchen/tools/odin-doc"
ODIN_DOC_JSON="$ROOT_DIR/vendor/matryoshka/kitchen/tools/odin-doc.json"
LIBCMARK="$ROOT_DIR/vendor/matryoshka/kitchen/tools"

if [ -f "$ODIN_DOC" ] && [ -f "$ODIN_DOC_JSON" ]; then
    # Patch the odin-doc config to use this repo's root.
    sed "s|PROJECT_ROOT|$ROOT_DIR|g" "$ODIN_DOC_JSON" > "$APIDOCS_DIR/odin-doc.json"
    cd "$APIDOCS_DIR"
    LD_LIBRARY_PATH="$LIBCMARK" "$ODIN_DOC" "$ROOT_DIR/matryoshka-http-template.odin-doc" ./odin-doc.json
    cd "$ROOT_DIR"
fi

rm -f matryoshka-http-template.odin-doc

echo "API docs generated in $APIDOCS_DIR"
