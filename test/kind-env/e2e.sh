#!/usr/bin/env bash
# Canonical Kind qualification entrypoint for the ExtProc-only dataplane.
# The implementation remains in the explicitly named suite so the same
# behavior can be invoked directly by focused debugging workflows.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
exec "$ROOT/test/kind-env/e2e-extproc.sh" "$@"
