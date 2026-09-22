#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${OPENSHIFT_E2E_STATE:-"$ROOT/.openshift-state"}
KUBECONFIG_FILE=${OPENSHIFT_KUBECONFIG:-"$STATE/kubeconfig"}
RUN_ID=${OPENSHIFT_E2E_RUN_ID:-"$(date -u +%Y%m%d%H%M%S)-$RANDOM"}
# OpenShift resource names are DNS-1123 values. Keep the human-selected run
# identity for evidence only after normalizing it once at the boundary so all
# derived namespaces, routes, SCCs, and image tags are valid resource names.
RUN_ID=$(printf '%s' "$RUN_ID" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//' | cut -c1-48)
[[ -n "$RUN_ID" ]] || { echo "OPENSHIFT_E2E_RUN_ID must contain at least one DNS-1123 character" >&2; exit 1; }
EVIDENCE="$STATE/evidence/$RUN_ID/baseline"
mkdir -p "$EVIDENCE"

# A rerun after provisioning may already have a MaaS-resolved tenant
# namespace. Preserve it only when the live AITenant reports the same value;
# never carry an arbitrary or foreign namespace forward from stale state.
TENANT_NAMESPACE="xmp-tenant-$RUN_ID"

command -v oc >/dev/null || { echo "oc is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
[[ -s "$KUBECONFIG_FILE" ]] || { echo "isolated kubeconfig not found: $KUBECONFIG_FILE" >&2; exit 1; }

OC=(oc --kubeconfig "$KUBECONFIG_FILE")
export KUBECONFIG="$KUBECONFIG_FILE"
"${OC[@]}" whoami >/dev/null
"${OC[@]}" version -o json >"$EVIDENCE/version.json"
"${OC[@]}" get clusterversion version -o json >"$EVIDENCE/clusterversion.json"
"${OC[@]}" get nodes -o json >"$EVIDENCE/nodes.json"
"${OC[@]}" get clusteroperators -o json >"$EVIDENCE/clusteroperators.json"
"${OC[@]}" get dscinitializations.datasciencecluster.opendatahub.io -A -o json >"$EVIDENCE/dscinitializations.json" 2>/dev/null || :
"${OC[@]}" get datascienceclusters.datasciencecluster.opendatahub.io -A -o json >"$EVIDENCE/datascienceclusters.json" 2>/dev/null || :
"${OC[@]}" get crd -o json >"$EVIDENCE/crds.json"
"${OC[@]}" get gateway,httproute,externalmodel,externalprovider,aitenant -A -o json >"$EVIDENCE/routing-resources.json" 2>/dev/null || :
"${OC[@]}" get deployment -A -o json >"$EVIDENCE/deployments.json"
"${OC[@]}" get scc -o json >"$EVIDENCE/scc.json" 2>/dev/null || :
"${OC[@]}" get namespace -o json >"$EVIDENCE/namespaces.json"

if [[ -s "$STATE/run.env" ]]; then
  previous_tenant_namespace=$(sed -n 's/^export OPENSHIFT_E2E_TENANT_NAMESPACE=//p' "$STATE/run.env" | tail -n 1)
  resolved_tenant_namespace=$("${OC[@]}" get aitenant "${OPENSHIFT_E2E_AITENANT_NAME:-models-as-a-service}" -n ai-tenants -o jsonpath='{.status.tenantNamespace}' 2>/dev/null || true)
  if [[ -n "$resolved_tenant_namespace" && ( "$previous_tenant_namespace" == "$TENANT_NAMESPACE" || "$previous_tenant_namespace" == "$resolved_tenant_namespace" ) ]]; then
    TENANT_NAMESPACE="$resolved_tenant_namespace"
  elif [[ -n "$previous_tenant_namespace" && "$previous_tenant_namespace" != "$TENANT_NAMESPACE" && "$previous_tenant_namespace" == "$resolved_tenant_namespace" ]]; then
    TENANT_NAMESPACE="$previous_tenant_namespace"
  fi
fi

# A healthy MaaS deployment is not sufficient evidence of Praxis opt-in
# support.  Require an explicit provenance record for the exact deployed image
# before creating any AITenant; this prevents mixing the controller with an
# older MaaS image that still renders IPP ExtProc resources.
MAAS_IMAGE="$("${OC[@]}" get deployment maas-controller -n redhat-ods-applications -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
printf '%s\n' "$MAAS_IMAGE" >"$EVIDENCE/maas-image.txt"
if [[ -z "$MAAS_IMAGE" ]]; then
  printf '%s\n' 'MaaS is absent; provision.sh must install the pinned source-matched platform stack before creating an AITenant.' >"$EVIDENCE/maas-compatibility.txt"
else
  COMPAT_PROOF=${MAAS_PRAXIS_COMPATIBILITY_PROOF:-"$STATE/maas-praxis-compatibility.env"}
  if [[ ! -s "$COMPAT_PROOF" ]]; then
    cat >&2 <<EOF
MaaS Praxis compatibility is not proven; refusing to provision.
Installed MaaS image: $MAAS_IMAGE
Required behavior: maas.opendatahub.io/payload-processing-type=praxis must
skip MaaS/IPP payload-processing resources before ai-gateway-controller runs.
Provide a provenance file at $COMPAT_PROOF containing the exact image and
source commit from the matching build. Do not use a second MaaS controller.
EOF
    exit 1
  fi
  proof_image=$(awk -F= '$1 == "image" { print substr($0, index($0, "=") + 1); exit }' "$COMPAT_PROOF")
  proof_commit=$(awk -F= '$1 == "source_commit" { print substr($0, index($0, "=") + 1); exit }' "$COMPAT_PROOF")
  [[ "$proof_image" == "$MAAS_IMAGE" && "$MAAS_IMAGE" == *'@sha256:'* ]] || { echo 'MaaS compatibility proof does not match the installed immutable image' >&2; exit 1; }
  [[ -n "$proof_commit" && "$proof_commit" != *[[:space:]]* ]] || { echo 'MaaS compatibility proof lacks source_commit' >&2; exit 1; }
  printf 'image=%s\nsource_commit=%s\n' "$proof_image" "$proof_commit" >"$EVIDENCE/maas-compatibility-proof.txt"
fi

umask 077
cat >"$STATE/run.env" <<EOF
export OPENSHIFT_E2E_RUN_ID=$RUN_ID
export OPENSHIFT_E2E_STATE=$STATE
export OPENSHIFT_E2E_EVIDENCE_ROOT=$STATE/evidence/$RUN_ID
export OPENSHIFT_E2E_CONTROLLER_NAMESPACE=xmp-controller-$RUN_ID
export OPENSHIFT_E2E_TENANT_NAMESPACE=$TENANT_NAMESPACE
export OPENSHIFT_E2E_BACKEND_NAMESPACE=xmp-provider-$RUN_ID
export OPENSHIFT_E2E_GATEWAY_NAMESPACE=openshift-ingress
export OPENSHIFT_E2E_GATEWAY_NAME=xmp-gateway-$RUN_ID
# The default OpenShift Route host appends the ingress service name to the
# route name. Keep that first DNS label within 63 characters even on clusters
# with long run identifiers; the full run ID remains the ownership label.
export OPENSHIFT_E2E_REGISTRY_ROUTE=xmp-registry-${RUN_ID:0:24}
export OPENSHIFT_E2E_AITENANT_NAME=${OPENSHIFT_E2E_AITENANT_NAME:-models-as-a-service}
EOF
printf '%s\n' "$EVIDENCE"
