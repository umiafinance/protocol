#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

bun --filter @umia/abi codegen

if ! git diff --quiet smart-contracts/abi/src/generated.ts smart-contracts/abi/json; then
    echo "ABI codegen is out of date!"
    echo ""
    git diff --stat smart-contracts/abi/src/generated.ts smart-contracts/abi/json
    echo ""
    echo "Run 'just abi' and commit the result."
    exit 1
fi

echo "ABI codegen is up to date."
