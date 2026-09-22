#!/usr/bin/env bash
# Fixture-based regression test for the OpenShift narrative renderer.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
DEMO="$ROOT/test/openshift-env/demo.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

make_result() {
  local dir=$1 status=$2
  mkdir -p "$dir"
  jq -n --arg status "$status" '{suite:"fixture",functional:$status,assertions:[{id:"1",name:"Unauthenticated request",status:(if $status=="FAIL" then "FAIL" else "PASS" end),boundary:"authorization",detail:(if $status=="FAIL" then "fixture failed" else "HTTP 401" end)}]}' >"$dir/results.json"
}

assert_titles() {
  local output=$1
  for title in \
    'TEST 1: Deployment readiness' \
    'TEST 2: Tenant ExtProc selection' \
    'TEST 3: Route acceptance' \
    'TEST 4: Public TLS and authentication' \
    'TEST 5: Provider A request' \
    'TEST 6: Unknown model' \
    'TEST 7: Provider A to Provider B switch' \
    'TEST 8: Semantic no-op' \
    'TEST 9: Invalid-overlay last-known-good behavior' \
    'TEST 10: Provider credential enforcement' \
    'TEST 11: Tenant security' \
    'TEST 12: Reset and credential revocation'; do
    grep -F "$title" <<<"$output" >/dev/null
  done
}

make_result "$TMP/pass" PASS
pass_output=$("$DEMO" --non-interactive --evidence "$TMP/pass")
assert_titles "$pass_output"
grep -F 'RESULT' <<<"$pass_output" >/dev/null
grep -F 'NOT DEMONSTRATED' <<<"$pass_output" >/dev/null
if grep -F "$TMP" <<<"$pass_output" >/dev/null; then exit 1; fi
if grep -Eiq 'Authorization:[[:space:]]+Bearer[[:space:]]+[A-Za-z0-9._~-]{8,}|x-api-key[=:][[:space:]]+[A-Za-z0-9._~-]{8,}' <<<"$pass_output"; then exit 1; fi

make_result "$TMP/fail" FAIL
if "$DEMO" --evidence "$TMP/fail" >"$TMP/fail.txt"; then
  echo 'FAIL fixture unexpectedly returned success' >&2
  exit 1
fi
grep -F 'FAIL' "$TMP/fail.txt" >/dev/null

make_result "$TMP/missing" PASS
missing_output=$("$DEMO" --evidence "$TMP/missing")
grep -F 'NOT DEMONSTRATED' <<<"$missing_output" >/dev/null

make_result "$TMP/redaction" PASS
jq '.assertions[0].detail="Authorization: Bearer fixture-secret-value"' "$TMP/redaction/results.json" >"$TMP/redaction/results.tmp"
mv "$TMP/redaction/results.tmp" "$TMP/redaction/results.json"
redacted_output=$("$DEMO" --evidence "$TMP/redaction")
if grep -F 'fixture-secret-value' <<<"$redacted_output"; then exit 1; fi

jq '.assertions[0].detail="x-api-key : fixture-secret-value"' "$TMP/redaction/results.json" >"$TMP/redaction/results.tmp"
mv "$TMP/redaction/results.tmp" "$TMP/redaction/results.json"
redacted_output=$("$DEMO" --evidence "$TMP/redaction")
if grep -F 'fixture-secret-value' <<<"$redacted_output"; then exit 1; fi

echo 'demo formatter fixtures: PASS, FAIL, missing evidence, NOT DEMONSTRATED, and redaction passed'
