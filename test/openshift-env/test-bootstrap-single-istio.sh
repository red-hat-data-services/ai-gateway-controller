#!/usr/bin/env bash
set -euo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bootstrap.sh

grep -Fq 'for kuadrant_config in authorino.yaml limitador.yaml kuadrant.yaml' "$script" || {
  echo 'bootstrap does not enumerate the three explicit Kuadrant resources' >&2
  exit 1
}
if grep -Fq 'config/install/configure/standard" |' "$script" ||
   grep -Fq 'config/install/configure/standard/sail.yaml' "$script"; then
  echo 'bootstrap must not apply the aggregate Kuadrant standard configuration' >&2
  exit 1
fi
grep -Fq 'get istio.sailoperator.io -A -o json' "$script" || {
  echo 'missing fail-closed Sail Istio guard' >&2
  exit 1
}
grep -Fq 'ISTIO_DEPLOYMENT_COUNT' "$script" || {
  echo 'missing single-istiod gate' >&2
  exit 1
}

echo 'bootstrap single-Istio contract: PASS'
