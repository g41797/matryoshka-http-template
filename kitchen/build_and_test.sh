#!/usr/bin/env bash

set -euo pipefail

GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

OPTS=(none minimal size speed aggressive)

BUILDS=(
    pipeline
    handlers
    examples
    http_cs
)

TESTS=(
    tests/unit/pipeline
    tests/unit/handlers
    tests/unit/http_cs
    tests/functional
    tests/functional/async
)

DOCS=(
    .
    pipeline
    handlers
    examples
    http_cs
)

echo "${BLUE}Starting flat local CI...${NC}"

if ! command -v odin >/dev/null 2>&1; then
    echo "Error: odin compiler not found in PATH"
    exit 1
fi

export ODIN_TEST_THREADS=1

for opt in "${OPTS[@]}"; do
    echo
    echo "${BLUE}--- opt: ${opt} ---${NC}"

    for path in "${BUILDS[@]}"; do
        if [ -d "./${path}" ] && [ -n "$(find ./${path} -maxdepth 1 -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
            echo "  build ${path}..."
            if [ "${opt}" = "none" ]; then
                odin build ./${path}/ -build-mode:lib -vet -strict-style -o:none -debug
            else
                odin build ./${path}/ -build-mode:lib -vet -strict-style -o:"${opt}"
            fi
        fi
    done

    for path in "${TESTS[@]}"; do
        if [ -d "./${path}" ] && [ -n "$(find ./${path} -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
            echo "  test ${path}/..."
            if [ "${opt}" = "none" ]; then
                odin test ./${path}/ -vet -strict-style -disallow-do -o:none -debug -define:ODIN_TEST_FANCY=false
            else
                odin test ./${path}/ -vet -strict-style -disallow-do -o:"${opt}" -define:ODIN_TEST_FANCY=false -define:ODIN_TEST_THREADS=1
            fi
        fi
    done

    echo "${GREEN}  pass: ${opt}${NC}"
done

echo
echo "${BLUE}--- doc smoke test ---${NC}"
for path in "${DOCS[@]}"; do
    if [ -d "./${path}" ] && [ -n "$(find ./${path} -maxdepth 1 -name '*.odin' -size +0c 2>/dev/null | head -1)" ]; then
        odin doc ./${path}/
    fi
done
echo "${GREEN}  docs OK${NC}"

echo
echo "${GREEN}ALL CHECKS PASSED${NC}"
