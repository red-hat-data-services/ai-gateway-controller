#!/usr/bin/env bash
set -euo pipefail

script=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/destroy.sh
tenant_line=$(grep -n 'delete aitenant' "$script" | head -1 | cut -d: -f1)
namespace_line=$(grep -n 'delete namespace' "$script" | head -1 | cut -d: -f1)
gateway_line=$(grep -n 'delete gateway' "$script" | tail -1 | cut -d: -f1)
timeout_line=$(grep -n 'AITenant finalization timed out' "$script" | cut -d: -f1)

[[ -n "$tenant_line" && -n "$namespace_line" && -n "$gateway_line" ]] || {
  echo "destroy ordering markers are missing" >&2
  exit 1
}
(( tenant_line < namespace_line )) || { echo "AITenant must be deleted before namespaces" >&2; exit 1; }
(( tenant_line < gateway_line )) || { echo "AITenant must be deleted before Gateway" >&2; exit 1; }
[[ -n "$timeout_line" ]] || { echo "finalization timeout guard is missing" >&2; exit 1; }
grep -q 'shared MaaS AITenant metadata restored' "$script" || { echo "shared AITenant restoration path is missing" >&2; exit 1; }
grep -q 'tenant and namespace retained' "$script" || { echo "shared AITenant namespace protection is missing" >&2; exit 1; }
grep -q 'shared Authorino identity changed; refusing volume restoration' "$script" || { echo "shared Authorino identity guard is missing" >&2; exit 1; }
grep -q 'xmp-service-ca-' "$script" || { echo "run-owned Authorino CA cleanup is missing" >&2; exit 1; }

echo "destroy ordering: PASS"
