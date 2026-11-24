#!/usr/bin/env bash
# Verify a contract on Basescan using forge's standard-json but with the remappings
# recorded in the DEPLOYED artifact's metadata (forge's verify path infers an extra
# `test/=lib/continuous-clearing-auction/test/` remapping, which changes the CBOR
# metadata tail and makes Etherscan's exact-bytecode check fail).
#
# Usage: ./verify-fixed.sh <address> <path:Name> [constructor-args-hex-no-0x] [extra forge args...]
set -euo pipefail
cd "$(dirname "$0")"
ADDR=$1; FQN=$2; CTOR=${3:-}; shift 2; [ $# -gt 0 ] && shift || true
SRC=${FQN%%:*}; NAME=${FQN##*:}
ART="out/$(basename "$SRC")/$NAME.json"
[ -f "$ART" ] || { echo "artifact $ART not found"; exit 1; }
TMP=$(mktemp -d)
forge verify-contract "$ADDR" "$FQN" --chain 8453 --compiler-version 0.8.26 \
  "$@" --show-standard-json-input > "$TMP/in.json"
jq --argjson r "$(jq '.metadata.settings.remappings' "$ART")" \
  '.settings.remappings = $r' "$TMP/in.json" > "$TMP/fixed.json"
RESPONSE=$(curl -fsS "https://api.etherscan.io/v2/api?chainid=8453" \
  --data-urlencode "apikey=$ETHERSCAN_API_KEY" \
  --data-urlencode "module=contract" --data-urlencode "action=verifysourcecode" \
  --data-urlencode "contractaddress=$ADDR" \
  --data-urlencode "codeformat=solidity-standard-json-input" \
  --data-urlencode "contractname=$FQN" \
  --data-urlencode "compilerversion=v0.8.26+commit.8a97fa7a" \
  ${CTOR:+--data-urlencode "constructorArguements=$CTOR"} \
  --data-urlencode "sourceCode@$TMP/fixed.json")
GUID=$(jq -er '.result | select(type == "string" and length > 0)' <<< "$RESPONSE")
if [ "$(jq -r '.status' <<< "$RESPONSE")" != "1" ]; then
  echo "Verification submission failed: $GUID" >&2
  exit 1
fi
echo "GUID: $GUID"
for i in $(seq 1 12); do sleep 10
  RESPONSE=$(curl -fsS "https://api.etherscan.io/v2/api?chainid=8453&module=contract&action=checkverifystatus&guid=$GUID&apikey=$ETHERSCAN_API_KEY")
  R=$(jq -er '.result | select(type == "string" and length > 0)' <<< "$RESPONSE")
  echo "  $R"
  if [ "$(jq -r '.status' <<< "$RESPONSE")" = "1" ]; then
    exit 0
  fi
  case "$R" in "Pending in queue") continue;; *) exit 1;; esac
done
echo "Verification is still pending after 12 checks; retry the status check with GUID $GUID." >&2
exit 1
