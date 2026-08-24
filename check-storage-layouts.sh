#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

CONTRACTS=("UmiaHub" "UmiaMarketCore" "Venture")
SNAPSHOT_DIR=".storage-layouts"
failed=0

for contract in "${CONTRACTS[@]}"; do
    snapshot="$SNAPSHOT_DIR/$contract.txt"
    current=$(forge inspect "$contract" storage-layout)

    if [ ! -f "$snapshot" ]; then
        echo "MISSING: $snapshot — run 'just forge-update-storage-layouts' to create it"
        failed=1
        continue
    fi

    if ! diff -q <(printf '%s\n' "$current") "$snapshot" > /dev/null 2>&1; then
        echo "MISMATCH: $contract storage layout has changed!"
        echo "--- snapshot ($snapshot)"
        echo "+++ current"
        diff --color=auto "$snapshot" <(printf '%s\n' "$current") || true
        echo ""
        echo "If this change is intentional, update all snapshots:"
        echo "  just forge-update-storage-layouts"
        failed=1
    else
        echo "OK: $contract"
    fi
done

if [ "$failed" -ne 0 ]; then
    echo ""
    echo "Storage layout check failed. Upgradeable contracts must maintain layout compatibility."
    exit 1
fi

echo "All storage layout snapshots match."
