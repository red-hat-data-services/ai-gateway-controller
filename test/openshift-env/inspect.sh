#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${OPENSHIFT_E2E_STATE:-"$ROOT/.openshift-state"}
# shellcheck disable=SC1091
source "$STATE/run.env"
OC=(oc --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}")
OUT=${1:-"$OPENSHIFT_E2E_EVIDENCE_ROOT/inspect-$(date -u +%Y%m%dT%H%M%SZ)"}
mkdir -p "$OUT"
for ns in "$OPENSHIFT_E2E_CONTROLLER_NAMESPACE" "$OPENSHIFT_E2E_TENANT_NAMESPACE" "$OPENSHIFT_E2E_BACKEND_NAMESPACE" "$OPENSHIFT_E2E_GATEWAY_NAMESPACE"; do
  "${OC[@]}" get all -n "$ns" -o json >"$OUT/$ns-all.json" 2>/dev/null || :
  "${OC[@]}" get role,rolebinding,serviceaccount,httproute,externalmodel,externalprovider,configmap -n "$ns" -o json >"$OUT/$ns-resources.json" 2>/dev/null || :
done
"${OC[@]}" get gateway -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" -o json >"$OUT/gateway.json" 2>/dev/null || :
printf '%s\n' "$OUT"
