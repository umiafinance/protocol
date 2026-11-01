#!/usr/bin/env bash
# Exercise the actual verifier with local command fixtures, without API keys,
# deployed contracts, network requests, or the real polling delay.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=$(mktemp -d "$ROOT/.verify-fixed-test.XXXXXX")
trap '[[ "$WORK" == "$ROOT"/.verify-fixed-test.* ]] && rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/out/Fixture.sol"
cp "$ROOT/verify-fixed.sh" "$WORK/verify-fixed.sh"
printf '%s\n' '{"metadata":{"settings":{"remappings":["expected/=lib/expected/"]}}}' > "$WORK/out/Fixture.sol/Fixture.json"

cat > "$WORK/bin/forge" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"language":"Solidity","sources":{},"settings":{"remappings":["wrong/=lib/wrong/"]}}'
SH
cat > "$WORK/bin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *action=verifysourcecode* ]]; then
  echo submit >> "$CALLS"
  # The submitted source must still use the artifact's recorded remappings.
  for arg in "$@"; do
    if [[ "$arg" == sourceCode@* ]]; then
      jq -e '.settings.remappings == ["expected/=lib/expected/"]' "${arg#sourceCode@}" >/dev/null
    fi
  done
  printf '%s\n' "$SUBMISSION"
else
  echo poll >> "$CALLS"
  if [[ "${PENDING_FIRST:-0}" == 1 ]] && [[ $(grep -c '^poll$' "$CALLS") == 1 ]]; then
    printf '%s\n' '{"status":"0","message":"NOTOK","result":"Pending in queue"}'
  else
    printf '%s\n' "$POLL"
  fi
fi
SH
chmod +x "$WORK/bin/forge" "$WORK/bin/curl" "$WORK/bin/sleep"
export PATH="$WORK/bin:$PATH" ETHERSCAN_API_KEY=local-fixture
export CALLS="$WORK/calls"
OK='{"status":"1","message":"OK","result":"test-guid"}'
VERIFIED='{"status":"1","message":"OK","result":"Pass - Verified"}'
failures=0

run_case() {
  local name=$1 expected=$2 status=0
  : > "$CALLS"
  bash "$WORK/verify-fixed.sh" 0x1111111111111111111111111111111111111111 src/Fixture.sol:Fixture > "$WORK/output" 2>&1 || status=$?
  if [[ "$expected" == success && "$status" != 0 ]] || [[ "$expected" == failure && "$status" == 0 ]]; then
    echo "FAIL $name: exit $status"
    cat "$WORK/output"
    failures=$((failures + 1))
  else
    echo "PASS $name: exit $status"
  fi
}

export SUBMISSION="$OK" POLL="$VERIFIED"
run_case verified success
export PENDING_FIRST=1
run_case pending-then-verified success
export PENDING_FIRST=0
export POLL='{"status":"0","message":"NOTOK","result":"Fail - Unable to verify"}'
run_case rejected failure
export POLL='{"status":"0","message":"NOTOK","result":"Pending in queue"}'
run_case polling-exhausted failure
export SUBMISSION='{"status":"0","message":"NOTOK","result":"Invalid API Key"}' POLL="$VERIFIED"
run_case submission-refused failure
if grep -q '^poll$' "$CALLS"; then
  echo 'FAIL a refused submission must not enter polling'
  failures=$((failures + 1))
fi
export SUBMISSION="$OK" POLL='not-json'
run_case malformed-response failure
[[ "$failures" == 0 ]]
