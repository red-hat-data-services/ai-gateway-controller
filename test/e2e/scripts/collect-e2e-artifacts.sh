#!/usr/bin/env bash
# Artifact collection copied from maas-billing test/e2e/scripts/auth_utils.sh
# (collect_authorino_logs_redacted, collect_maas_crs, collect_cluster_state,
# collect_namespace_pod_logs, collect_e2e_artifacts).
#
# That script is what billing CI actually uploads. Group-test was not running
# it: the pinned models-as-a-service checkout calls `kubectl` only, and the
# Konflux task image often has `oc` alone, so every get failed closed and
# maas-crs/ never appeared.
#
# DSC, DSCI, HTTPRoutes, and Gateways are dumped with the same
# `get <crd> -A -o yaml` loop billing uses for MaaS CRs. Billing only prints
# those as wide lines in cluster-state.log.
#
# Usage:
#   ARTIFACT_DIR=/path ./test/e2e/scripts/collect-e2e-artifacts.sh
#
# Container runtime: not used. kubectl, or oc if kubectl is absent.

set -uo pipefail

if ! command -v kubectl >/dev/null 2>&1 && command -v oc >/dev/null 2>&1; then
  kubectl() { oc "$@"; }
fi

DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-opendatahub}"
MAAS_SUBSCRIPTION_NAMESPACE="${MAAS_SUBSCRIPTION_NAMESPACE:-models-as-a-service}"
AUTHORINO_NAMESPACE="${AUTHORINO_NAMESPACE:-kuadrant-system}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-redhat-ods-operator}"
APPLICATIONS_NAMESPACE="${APPLICATIONS_NAMESPACE:-redhat-ods-applications}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
LLM_NAMESPACE="${LLM_NAMESPACE:-llm}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"

_derive_infra_namespace() {
  case "$DEPLOYMENT_NAMESPACE" in
    redhat-ods-applications) echo "redhat-ai-gateway-infra" ;;
    opendatahub) echo "odh-ai-gateway-infra" ;;
    *) echo "$DEPLOYMENT_NAMESPACE" ;;
  esac
}
MAAS_API_DEPLOYMENT_NAMESPACE="${MAAS_API_DEPLOYMENT_NAMESPACE:-$(_derive_infra_namespace)}"

ARTIFACTS_DIR="${ARTIFACTS_DIR:-${ARTIFACT_DIR:-${ARTIFACTS:-${LOG_DIR:-./test/e2e/reports}}}}"
mkdir -p "$ARTIFACTS_DIR"

redact_tokens() {
  sed -E \
    -e 's/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/****REDACTED_JWT****/g' \
    -e 's/"token":"[^"]*"/"token":"****"/g' \
    -e 's/"token": "[^"]*"/"token": "****"/g' \
    -e 's/(Bearer )[^[:space:]]+/\1****/g' \
    -e 's/("spec":\s*\{[^}]*"token":\s*)"[^"]*"/\1"****"/g' \
    -e 's/token=[A-Za-z0-9_-]+\.?[A-Za-z0-9_-]*\.?[A-Za-z0-9_-]*/token=****/g' \
    2>/dev/null || cat
}

collect_authorino_logs_redacted() {
  local outfile="${1:-$ARTIFACTS_DIR/authorino-debug.log}"
  mkdir -p "$(dirname "$outfile")"
  : > "$outfile"
  echo "Collecting Authorino logs (token-redacted) to $outfile"
  for ns in "$AUTHORINO_NAMESPACE" openshift-ingress; do
    for label in "app.kubernetes.io/name=authorino" "authorino-resource=authorino"; do
      if kubectl get pods -n "$ns" -l "$label" --no-headers 2>/dev/null | head -1 | grep -q .; then
        {
          echo "--- Authorino logs from $ns (label=$label) ---"
          kubectl logs -n "$ns" -l "$label" --tail=2000 --all-containers=true 2>/dev/null || true
        } | redact_tokens >> "$outfile"
        break
      fi
    done
  done
  [[ -s "$outfile" ]] && echo "  Saved to $outfile" || true
}

# Same CRD list as maas-billing auth_utils.sh collect_maas_crs.
MAAS_CRDS=(
  "aitenants.maas.opendatahub.io"
  "configs.maas.opendatahub.io"
  "externalmodels.maas.opendatahub.io"
  "maasauthpolicies.maas.opendatahub.io"
  "maasmodelrefs.maas.opendatahub.io"
  "maassubscriptions.maas.opendatahub.io"
  "maastenantconfigs.maas.opendatahub.io"
  "tenants.maas.opendatahub.io"
)
INFERENCE_CRDS=(
  "externalmodels.inference.opendatahub.io"
  "externalproviders.inference.opendatahub.io"
)
AIGATEWAY_CRDS=(
  "aigateways.components.platform.opendatahub.io"
  "llmbatchgateways.batch.llm-d.ai"
)
# Same get -A -o yaml loop; billing only wide-lists these in cluster-state.log.
PLATFORM_CRDS=(
  "datascienceclusters.datasciencecluster.opendatahub.io"
  "dscinitializations.dscinitialization.opendatahub.io"
  "httproutes.gateway.networking.k8s.io"
  "gateways.gateway.networking.k8s.io"
)
ALL_CRDS=("${MAAS_CRDS[@]}" "${INFERENCE_CRDS[@]}" "${AIGATEWAY_CRDS[@]}" "${PLATFORM_CRDS[@]}")

_crd_artifact_name() {
  local crd="$1"
  local group="${crd#*.}"
  local resource="${crd%%.*}"
  case "$group" in
    maas.opendatahub.io)                echo "$resource" ;;
    inference.opendatahub.io)           echo "inference-${resource}" ;;
    components.platform.opendatahub.io) echo "$resource" ;;
    batch.llm-d.ai)                     echo "$resource" ;;
    datasciencecluster.opendatahub.io)  echo "$resource" ;;
    dscinitialization.opendatahub.io)   echo "$resource" ;;
    gateway.networking.k8s.io)          echo "$resource" ;;
    *)                                  echo "${resource}-${group%%.*}" ;;
  esac
}

collect_maas_crs() {
  local outdir="${1:-$ARTIFACTS_DIR/maas-crs}"
  mkdir -p "$outdir"
  echo "Collecting MaaS CR definitions to $outdir"

  local total=0
  for crd in "${ALL_CRDS[@]}"; do
    local artifact_name
    artifact_name=$(_crd_artifact_name "$crd")
    local outfile="$outdir/${artifact_name}.yaml"
    : > "$outfile"

    # -A works for both namespaced (all namespaces) and cluster-scoped resources
    local yaml
    yaml=$(kubectl get "$crd" -A -o yaml 2>/dev/null || true)
    if [[ -n "$yaml" ]] && ! echo "$yaml" | grep -q 'items: \[\]'; then
      echo "$yaml" | redact_tokens >> "$outfile"
      total=$((total + 1))
    fi

    if [[ ! -s "$outfile" ]]; then
      rm -f "$outfile"
    fi
  done

  if [[ "$total" -eq 0 ]]; then
    echo "  No MaaS CRs found on the cluster"
    echo "No MaaS CRs found at $(date -Iseconds 2>/dev/null || date)" > "$outdir/no-crs-found.log"
  else
    echo "  Saved $total resource type(s) to $outdir"
  fi
}

collect_cluster_state() {
  local outdir="${1:-$ARTIFACTS_DIR}"
  mkdir -p "$outdir"
  echo "Collecting cluster state to $outdir"
  {
    echo "=== Cluster state $(date -Iseconds 2>/dev/null || date) ==="
    kubectl get nodes -o wide 2>/dev/null || true
    kubectl get ns 2>/dev/null || true
    echo ""
    echo "--- MaaS controller namespace ($DEPLOYMENT_NAMESPACE) ---"
    kubectl get all -n "$DEPLOYMENT_NAMESPACE" 2>/dev/null || true
    echo ""
    echo "--- MaaS API deployment namespace ($MAAS_API_DEPLOYMENT_NAMESPACE) ---"
    kubectl get all -n "$MAAS_API_DEPLOYMENT_NAMESPACE" 2>/dev/null || true
    echo ""
    echo "--- RHOAI Operator namespace ($OPERATOR_NAMESPACE) ---"
    kubectl get pods,deployments,csv -n "$OPERATOR_NAMESPACE" -o wide 2>/dev/null || true
    echo ""
    echo "--- RHOAI Applications namespace ($APPLICATIONS_NAMESPACE) ---"
    kubectl get pods,deployments,services -n "$APPLICATIONS_NAMESPACE" -o wide 2>/dev/null || true
    echo ""
    echo "--- DSC / DSCI ---"
    kubectl get datasciencecluster,dscinitialization -o wide 2>/dev/null || true
    echo ""
    echo "--- Gateway namespace ($GATEWAY_NAMESPACE) ---"
    kubectl get pods,services -n "$GATEWAY_NAMESPACE" -o wide 2>/dev/null || true
    echo ""
    echo "--- AuthPolicies ---"
    kubectl get authpolicies -A 2>/dev/null || true
    echo ""
    echo "--- TokenRateLimitPolicies ---"
    kubectl get tokenratelimitpolicies -A 2>/dev/null || true
    echo ""
    echo "--- MaaS CRs (maas.opendatahub.io) ---"
    kubectl get configs.maas.opendatahub.io -o wide 2>/dev/null || true
    kubectl get aitenants.maas.opendatahub.io -A -o wide 2>/dev/null || true
    kubectl get tenants.maas.opendatahub.io -A -o wide 2>/dev/null || true
    kubectl get maasmodelrefs -n "$DEPLOYMENT_NAMESPACE" 2>/dev/null || true
    kubectl get maasauthpolicies,maassubscriptions -n "$MAAS_SUBSCRIPTION_NAMESPACE" 2>/dev/null || true
    kubectl get maastenantconfigs -n "$MAAS_SUBSCRIPTION_NAMESPACE" 2>/dev/null || true
    kubectl get externalmodels.maas.opendatahub.io -A -o wide 2>/dev/null || true
    echo ""
    echo "--- Inference CRs (inference.opendatahub.io) ---"
    kubectl get externalmodels.inference.opendatahub.io -A -o wide 2>/dev/null || true
    kubectl get externalproviders.inference.opendatahub.io -A -o wide 2>/dev/null || true
    echo ""
    echo "--- AI Gateway CRs ---"
    kubectl get aigateways.components.platform.opendatahub.io -o wide 2>/dev/null || true
    kubectl get llmbatchgateways.batch.llm-d.ai -A -o wide 2>/dev/null || true
    echo ""
    echo "--- HTTPRoutes ---"
    kubectl get httproutes -A 2>/dev/null || true
    echo ""
    echo "--- Gateway ---"
    kubectl get gateway -A 2>/dev/null || true
  } > "$outdir/cluster-state.log" 2>&1
  echo "  Saved to $outdir/cluster-state.log"
}

collect_namespace_pod_logs() {
  local ns="${1:-$DEPLOYMENT_NAMESPACE}"
  local outdir="${2:-$ARTIFACTS_DIR/pod-logs}"
  mkdir -p "$outdir"
  echo "Collecting pod logs from namespace $ns to $outdir"
  for pod in $(kubectl get pods -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl logs -n "$ns" "$pod" --all-containers --tail=500 2>/dev/null | redact_tokens > "${outdir}/${pod}.log" || true
  done
  local count
  count=$(ls -1 "$outdir"/*.log 2>/dev/null | wc -l || echo 0)
  echo "  Saved $count pod log file(s) to $outdir"
}

collect_e2e_artifacts() {
  mkdir -p "$ARTIFACTS_DIR"
  echo ""
  echo "========== E2E Artifact Collection =========="
  echo "Artifact dir: $ARTIFACTS_DIR"
  collect_authorino_logs_redacted "$ARTIFACTS_DIR/authorino-debug.log"
  collect_cluster_state "$ARTIFACTS_DIR"
  collect_maas_crs "$ARTIFACTS_DIR/maas-crs"
  local ns
  for ns in \
    "$DEPLOYMENT_NAMESPACE" \
    "$MAAS_API_DEPLOYMENT_NAMESPACE" \
    "$MAAS_SUBSCRIPTION_NAMESPACE" \
    "$OPERATOR_NAMESPACE" \
    "$APPLICATIONS_NAMESPACE" \
    "$AUTHORINO_NAMESPACE" \
    "$GATEWAY_NAMESPACE" \
    "$LLM_NAMESPACE" \
    "$ISTIO_NAMESPACE" \
  ; do
    if kubectl get namespace "$ns" &>/dev/null; then
      collect_namespace_pod_logs "$ns" "$ARTIFACTS_DIR/pod-logs/$ns"
    else
      echo "  Skipping namespace $ns (not found)"
    fi
  done
  echo "=============================================="
}

collect_e2e_artifacts
