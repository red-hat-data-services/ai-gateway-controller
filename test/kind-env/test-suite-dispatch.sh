#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/test/kind-env/e2e.sh"

grep -Fq 'e2e-extproc.sh' "$SCRIPT" || { echo 'canonical entrypoint does not select the ExtProc suite' >&2; exit 1; }
if rg -q 'E2E_EXT_PROC_ONLY|E2E_SUITE|transition|deploy/praxis' "$SCRIPT"; then
  echo 'obsolete suite dispatch remains in e2e.sh' >&2
  exit 1
fi

echo 'Kind suite dispatch: PASS'
