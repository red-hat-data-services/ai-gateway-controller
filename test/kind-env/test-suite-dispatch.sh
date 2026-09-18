#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/test/kind-env/e2e.sh"

dispatch_guard=$(rg -n '^if \[\[ "\$SUITE" != transition \]\]; then$' "$SCRIPT" | cut -d: -f1)
routing_branch=$(rg -n '^if \[\[ "\$SUITE" == routing \]\]; then$' "$SCRIPT" | cut -d: -f1)
finalize=$(rg -n '^finalize_results\(\) \{' "$SCRIPT" | cut -d: -f1)
transition_section=$(rg -n '^# Separate transition tenant:' "$SCRIPT" | cut -d: -f1)
routing_finalize=$(sed -n "$((routing_branch + 1)),$((routing_branch + 6))p" "$SCRIPT")

[[ -n "$dispatch_guard" && -n "$routing_branch" && -n "$finalize" && -n "$transition_section" ]] || {
  echo 'suite dispatch markers are incomplete' >&2
  exit 1
}
(( dispatch_guard < finalize )) || { echo 'routing setup guard is missing or misplaced' >&2; exit 1; }
(( finalize < transition_section )) || { echo 'transition suite is not separated from routing finalization' >&2; exit 1; }
grep -Fq 'finalize_results' <<<"$routing_finalize" || { echo 'routing suite does not finalize independently' >&2; exit 1; }
grep -Fq 'exit 0' <<<"$routing_finalize" || { echo 'routing suite does not exit before transition setup' >&2; exit 1; }

echo 'Kind suite dispatch: PASS'
