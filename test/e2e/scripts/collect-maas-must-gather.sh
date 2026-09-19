#!/usr/bin/env bash
# MaaS-specific cluster diagnostics for e2e / CI must-gather bundles.
#
# Standard `oc adm must-gather` does not include maas.opendatahub.io CRs, tenant
# readiness status, payload-processing, DataScienceCluster/DSCI, or worker-tenant
# namespaces. This script writes a self-contained tree under gather-maas/ (or the
# path you pass). Aligned with models-as-a-service auth_utils collect_maas_crs /
# collect_cluster_state (DSC, HTTPRoutes, MaaS + inference + aigateway CRDs).
#
# Usage:
#   ./test/e2e/scripts/collect-maas-must-gather.sh [/path/to/gather-maas]
#
# Environment (defaults match prow_run_ai_gateway_controller_test.sh / auth_utils):
#   DEPLOYMENT_NAMESPACE, MAAS_SUBSCRIPTION_NAMESPACE, AITENANT_NAMESPACE,
#   GATEWAY_NAMESPACE, AUTHORINO_NAMESPACE, LLM_NAMESPACE, ISTIO_NAMESPACE,
#   OPERATOR_NAMESPACE, APPLICATIONS_NAMESPACE,
#   MAAS_API_DEPLOYMENT_NAMESPACE (derived from DEPLOYMENT_NAMESPACE when unset)
set -uo pipefail

_dest="${1:-${ARTIFACT_DIR:-${ARTIFACTS_DIR:-./gather-maas}}}"
mkdir -p "$_dest"

DEPLOYMENT_NAMESPACE="${DEPLOYMENT_NAMESPACE:-opendatahub}"
MAAS_SUBSCRIPTION_NAMESPACE="${MAAS_SUBSCRIPTION_NAMESPACE:-models-as-a-service}"
AITENANT_NAMESPACE="${AITENANT_NAMESPACE:-ai-tenants}"
AUTHORINO_NAMESPACE="${AUTHORINO_NAMESPACE:-kuadrant-system}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-openshift-ingress}"
LLM_NAMESPACE="${LLM_NAMESPACE:-llm}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-redhat-ods-operator}"
APPLICATIONS_NAMESPACE="${APPLICATIONS_NAMESPACE:-redhat-ods-applications}"
DEFAULT_AITENANT_NAME="${DEFAULT_AITENANT_NAME:-models-as-a-service}"
DEFAULT_TENANT_CONFIG_NAME="${DEFAULT_TENANT_CONFIG_NAME:-default-tenant}"

_derive_infra_namespace() {
  case "$DEPLOYMENT_NAMESPACE" in
    redhat-ods-applications) echo "redhat-ai-gateway-infra" ;;
    opendatahub) echo "odh-ai-gateway-infra" ;;
    *) echo "$DEPLOYMENT_NAMESPACE" ;;
  esac
}
MAAS_API_DEPLOYMENT_NAMESPACE="${MAAS_API_DEPLOYMENT_NAMESPACE:-$(_derive_infra_namespace)}"

_log() {
  echo "$*" | tee -a "$_dest/collection.log"
}

_k() {
  if command -v oc >/dev/null 2>&1; then
    oc "$@"
  elif command -v kubectl >/dev/null 2>&1; then
    kubectl "$@"
  else
    return 127
  fi
}

_save_yaml() {
  local outfile="$1"
  shift
  mkdir -p "$(dirname "$outfile")"
  if _k get "$@" -o yaml >"$outfile" 2>"${outfile}.err"; then
    if [[ ! -s "$outfile" ]]; then
      echo "# empty result for: $*" >"$outfile"
    fi
  else
    {
      echo "# failed to collect: $*"
      cat "${outfile}.err" 2>/dev/null || true
    } >"$outfile"
  fi
  rm -f "${outfile}.err"
}

_save_text() {
  local outfile="$1"
  local label="$2"
  shift 2
  mkdir -p "$(dirname "$outfile")"
  {
    echo "=== ${label} ($(date -u +%Y-%m-%dT%H:%M:%SZ)) ==="
    "$@" 2>&1 || true
  } >"$outfile"
}

_save_events() {
  local ns="$1"
  local outfile="$_dest/namespaces/events-${ns}.txt"
  _save_text "$outfile" "events in ${ns}" \
    _k get events -n "$ns" --sort-by='.lastTimestamp'
}

_save_pod_logs_grep() {
  local ns="$1"
  local label_selector="$2"
  local pattern="$3"
  local outfile="$4"
  mkdir -p "$(dirname "$outfile")"
  {
    echo "=== logs ns=${ns} selector=${label_selector} pattern=${pattern} ==="
    local pod
    pod=$(_k get pods -n "$ns" -l "$label_selector" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -z "$pod" ]]; then
      echo "no pod found"
      _k get pods -n "$ns" -o wide 2>/dev/null || true
      return 0
    fi
    _k logs -n "$ns" "$pod" --since=45m 2>/dev/null | grep -iE "$pattern" | tail -500 || true
    echo ""
    echo "--- last 80 lines (unfiltered) ---"
    _k logs -n "$ns" "$pod" --since=45m 2>/dev/null | tail -80 || true
  } >"$outfile"
}

_resource_short_name() {
  local resource="$1"
  echo "${resource%%.*}"
}

_resource_is_namespaced() {
  local resource="$1"
  local short
  short="$(_resource_short_name "$resource")"
  local namespaced
  namespaced="$(_k api-resources --no-headers -o wide 2>/dev/null | awk -v r="$short" '$1==r {print $3; exit}')"
  [[ "${namespaced}" == "true" ]]
}

_resolve_cluster_resource() {
  local want="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if _k api-resources -o name 2>/dev/null | grep -qx "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

_collect_api_group_resources() {
  local group="$1"
  local outdir="$2"
  mkdir -p "$_dest/$outdir"
  local resource safe
  while IFS= read -r resource; do
    [[ -z "${resource}" ]] && continue
    safe="${resource//./-}"
    if _resource_is_namespaced "$resource"; then
      _save_yaml "$_dest/$outdir/${safe}-all.yaml" "$resource" -A
    else
      _save_yaml "$_dest/$outdir/${safe}-all.yaml" "$resource"
    fi
  done < <(_k api-resources --api-group="$group" -o name 2>/dev/null || true)
}

# Namespaces where MaaS / aigc HTTPRoutes typically live (static allowlist).
_httproute_static_namespaces() {
  printf '%s\n' \
    "$GATEWAY_NAMESPACE" \
    "$MAAS_SUBSCRIPTION_NAMESPACE" \
    "$MAAS_API_DEPLOYMENT_NAMESPACE" \
    "$AITENANT_NAMESPACE" \
    "$LLM_NAMESPACE" \
    "$DEPLOYMENT_NAMESPACE" \
    "$APPLICATIONS_NAMESPACE" \
    "$ISTIO_NAMESPACE"
}

# Dynamic tenant / e2e namespaces that often own HTTPRoutes.
_httproute_dynamic_namespaces() {
  _k get ns -o name 2>/dev/null \
    | sed 's#^namespace/##' \
    | grep -E '^(ai-tenant-|e2e-ait-|e2e-derive-|e2e-models-|e2e-worker)' \
    || true
}

_collect_gateway_api() {
  mkdir -p "$_dest/gateway-api"
  _collect_api_group_resources "gateway.networking.k8s.io" "gateway-api"

  local httproute_resource
  httproute_resource="$(_resolve_cluster_resource httproute \
    httproutes.gateway.networking.k8s.io \
    httproute.gateway.networking.k8s.io \
    httproutes \
    httproute || true)"
  if [[ -n "${httproute_resource}" ]]; then
    _save_yaml "$_dest/gateway-api/httproutes-cluster-all.yaml" "${httproute_resource}" -A
    _httproutes_wide_text() {
      _k get "${httproute_resource}" -A -o wide 2>/dev/null || true
      echo ''
      _k get "${httproute_resource}" -A -o custom-columns=\
NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.hostnames,GW:.spec.parentRefs[*].name,AGE:.metadata.creationTimestamp \
        2>/dev/null || true
    }
    _save_text "$_dest/gateway-api/httproutes-wide.txt" "HTTPRoutes (all namespaces)" \
      _httproutes_wide_text
    # Prefer maas-api-route YAML explicitly (common failure point for API/key tests).
    if _k get namespace "$MAAS_API_DEPLOYMENT_NAMESPACE" &>/dev/null; then
      _save_yaml "$_dest/gateway-api/httproute-maas-api-route.yaml" \
        "${httproute_resource}" maas-api-route -n "$MAAS_API_DEPLOYMENT_NAMESPACE"
    fi

    local ns
    while IFS= read -r ns; do
      [[ -z "$ns" ]] && continue
      if _k get namespace "$ns" &>/dev/null; then
        _save_yaml "$_dest/gateway-api/httproutes-${ns}.yaml" "${httproute_resource}" -n "$ns"
        _save_text "$_dest/gateway-api/httproutes-${ns}.txt" "HTTPRoutes in ${ns}" \
          _k get "${httproute_resource}" -n "$ns" -o wide
      fi
    done < <({ _httproute_static_namespaces; _httproute_dynamic_namespaces; } | sort -u)
  else
    _httproutes_missing_text() {
      _k api-resources 2>/dev/null | grep -i httproute || echo "no httproute API resource"
    }
    _save_text "$_dest/gateway-api/httproutes-wide.txt" "HTTPRoutes (resource not found)" \
      _httproutes_missing_text
  fi

  local gw_resource
  gw_resource="$(_resolve_cluster_resource gateway \
    gateways.gateway.networking.k8s.io \
    gateway.gateway.networking.k8s.io \
    gateways \
    gateway || true)"
  if [[ -n "${gw_resource}" ]]; then
    _save_yaml "$_dest/gateway-api/gateways-cluster-all.yaml" "${gw_resource}" -A
    _save_text "$_dest/gateway-api/gateways-wide.txt" "Gateways (all namespaces)" \
      _k get "${gw_resource}" -A -o wide
    if _k get namespace "$GATEWAY_NAMESPACE" &>/dev/null; then
      _save_yaml "$_dest/gateway-api/gateways-${GATEWAY_NAMESPACE}.yaml" "${gw_resource}" -n "$GATEWAY_NAMESPACE"
      # Default MaaS gateway used by e2e / AITenant bootstrap.
      _save_yaml "$_dest/gateway-api/gateway-maas-default-gateway.yaml" \
        "${gw_resource}" maas-default-gateway -n "$GATEWAY_NAMESPACE"
    fi
  fi

  local refgrant_resource
  refgrant_resource="$(_resolve_cluster_resource referencegrant \
    referencegrants.gateway.networking.k8s.io \
    referencegrant.gateway.networking.k8s.io \
    referencegrants \
    referencegrant || true)"
  if [[ -n "${refgrant_resource}" ]]; then
    _save_yaml "$_dest/gateway-api/referencegrants-cluster-all.yaml" "${refgrant_resource}" -A
  fi
}

# DataScienceCluster + DSCInitialization (operator enablement for MaaS / aigateway).
# Mirrors models-as-a-service auth_utils collect_cluster_state "DSC / DSCI".
_collect_dsc() {
  mkdir -p "$_dest/crs/dsc"
  _collect_api_group_resources "datasciencecluster.opendatahub.io" "crs/dsc"

  local dsc_resource dsci_resource
  dsc_resource="$(_resolve_cluster_resource datasciencecluster \
    datascienceclusters.datasciencecluster.opendatahub.io \
    datasciencecluster.datasciencecluster.opendatahub.io \
    datascienceclusters \
    datasciencecluster || true)"
  dsci_resource="$(_resolve_cluster_resource dscinitialization \
    dscinitializations.dscinitialization.opendatahub.io \
    dscinitializations.datasciencecluster.opendatahub.io \
    dscinitialization.dscinitialization.opendatahub.io \
    dscinitializations \
    dscinitialization || true)"

  _dsc_status_text() {
    echo '--- DataScienceCluster ---'
    if [[ -n "${dsc_resource}" ]]; then
      _k get "${dsc_resource}" -A -o wide 2>/dev/null || _k get "${dsc_resource}" -o wide 2>/dev/null || true
      echo ''
      local name
      for name in $(_k get "${dsc_resource}" -o name 2>/dev/null | sed 's#.*/##' || true); do
        echo "=== ${name} conditions ==="
        _k get "${dsc_resource}" "${name}" -o jsonpath='{range .status.conditions[*]}{.type}={.status} ({.reason}): {.message}{"\n"}{end}' 2>/dev/null || true
        echo ''
      done
    else
      echo 'DataScienceCluster API not found'
    fi
    echo '--- DSCInitialization ---'
    if [[ -n "${dsci_resource}" ]]; then
      _k get "${dsci_resource}" -A -o wide 2>/dev/null || _k get "${dsci_resource}" -o wide 2>/dev/null || true
    else
      echo 'DSCInitialization API not found'
    fi
  }
  _save_text "$_dest/summaries/dsc-status.txt" "DataScienceCluster / DSCInitialization" \
    _dsc_status_text

  if [[ -n "${dsc_resource}" ]]; then
    # Cluster-scoped on ODH/RHOAI; -A is harmless if namespaced.
    _save_yaml "$_dest/crs/dsc/datascienceclusters-all.yaml" "${dsc_resource}" -A
    # Common default name used by ODH/RHOAI e2e.
    _save_yaml "$_dest/crs/dsc/datasciencecluster-default-dsc.yaml" "${dsc_resource}" default-dsc
  fi
  if [[ -n "${dsci_resource}" ]]; then
    _save_yaml "$_dest/crs/dsc/dscinitializations-all.yaml" "${dsci_resource}" -A
  fi
}

_collect_kuadrant_policies() {
  mkdir -p "$_dest/kuadrant"
  local resource
  for resource in \
    authpolicies.kuadrant.io \
    tokenratelimitpolicies.kuadrant.io; do
    if _k api-resources -o name 2>/dev/null | grep -qx "$resource"; then
      _save_yaml "$_dest/kuadrant/${resource//./-}-all.yaml" "$resource" -A
      _save_text "$_dest/kuadrant/${resource//./-}-wide.txt" "$resource (all namespaces)" \
        _k get "$resource" -A -o wide
    fi
  done
}

_collect_istio_gateway_networking() {
  mkdir -p "$_dest/istio-gateway"
  for resource in \
    envoyfilters.networking.istio.io \
    destinationrules.networking.istio.io \
    serviceentries.networking.istio.io \
    virtualservices.networking.istio.io; do
    if _k api-resources -o name 2>/dev/null | grep -qx "$resource"; then
      _save_yaml "$_dest/istio-gateway/${resource//./-}-${GATEWAY_NAMESPACE}.yaml" \
        "$resource" -n "$GATEWAY_NAMESPACE"
    fi
  done
}

_collect_maas_inventory() {
  # Keep in sync with models-as-a-service auth_utils.sh MAAS_CRDS / INFERENCE_CRDS / AIGATEWAY_CRDS.
  _maas_resources_wide_text() {
    local kind
    for kind in \
      aitenants.maas.opendatahub.io \
      configs.maas.opendatahub.io \
      externalmodels.maas.opendatahub.io \
      maasauthpolicies.maas.opendatahub.io \
      maasmodelrefs.maas.opendatahub.io \
      maassubscriptions.maas.opendatahub.io \
      maastenantconfigs.maas.opendatahub.io \
      tenants.maas.opendatahub.io \
      externalmodels.inference.opendatahub.io \
      externalproviders.inference.opendatahub.io \
      aigateways.components.platform.opendatahub.io \
      llmbatchgateways.batch.llm-d.ai; do
      echo "--- ${kind} ---"
      _k get "${kind}" -A -o wide 2>/dev/null || _k get "${kind}" -o wide 2>/dev/null || echo '  (not found)'
      echo ''
    done
  }
  _save_text "$_dest/summaries/maas-resources-wide.txt" "MaaS / inference / aigateway CR inventory" \
    _maas_resources_wide_text
}

_log "=== MaaS must-gather started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
_log "dest=${_dest}"
_log "DEPLOYMENT_NAMESPACE=${DEPLOYMENT_NAMESPACE}"
_log "MAAS_SUBSCRIPTION_NAMESPACE=${MAAS_SUBSCRIPTION_NAMESPACE}"
_log "MAAS_API_DEPLOYMENT_NAMESPACE=${MAAS_API_DEPLOYMENT_NAMESPACE}"
_log "AITENANT_NAMESPACE=${AITENANT_NAMESPACE}"
_log "GATEWAY_NAMESPACE=${GATEWAY_NAMESPACE}"

cat >"$_dest/README.txt" <<EOF
MaaS e2e diagnostics (ai-gateway-controller)

This directory complements gather-openshift/ from oc adm must-gather.
OpenShift must-gather does not collect maas.opendatahub.io CRs or tenant
readiness details needed for default-tenant / AITenant flake debugging.

Key files for tenant-not-ready / webhook / routing failures:
  summaries/dsc-status.txt
  crs/dsc/datasciencecluster-default-dsc.yaml
  crs/dsc/datascienceclusters-all.yaml
  crs/dsc/dscinitializations-all.yaml
  crs/maastenantconfig-default-tenant.yaml
  crs/aitenant-models-as-a-service.yaml
  crs/config-default.yaml
  summaries/tenant-readiness.txt
  summaries/maas-resources-wide.txt
  gateway-api/httproutes-wide.txt
  gateway-api/httproutes-cluster-all.yaml
  gateway-api/httproute-maas-api-route.yaml
  gateway-api/httproutes-<ns>.yaml (gateway, subscription, infra, llm, ai-tenant-*, e2e-*)
  gateway-api/gateway-maas-default-gateway.yaml
  crs/maas/*-all.yaml (every maas.opendatahub.io kind)
  crs/inference/*-all.yaml (inference.opendatahub.io ExternalModel/Provider)
  logs/maas-controller-tenant.log
  workloads/payload-processing-openshift-ingress.yaml
  namespaces/events-${MAAS_SUBSCRIPTION_NAMESPACE}.txt
  namespaces/events-${AITENANT_NAMESPACE}.txt
EOF

# --- summaries (quick jsonpath views) ---
mkdir -p "$_dest/summaries"
_tenant_readiness_text() {
  echo "--- MaasTenantConfig/${DEFAULT_TENANT_CONFIG_NAME} (${MAAS_SUBSCRIPTION_NAMESPACE}) ---"
  _k get maastenantconfig "${DEFAULT_TENANT_CONFIG_NAME}" -n "${MAAS_SUBSCRIPTION_NAMESPACE}" \
    -o jsonpath='phase={.status.phase}{"\n"}{range .status.conditions[*]}{.type}={.status} reason={.reason} msg={.message}{"\n"}{end}' \
    2>/dev/null || echo 'not found'
  echo ''
  echo "--- AITenant/${DEFAULT_AITENANT_NAME} (${AITENANT_NAMESPACE}) ---"
  _k get aitenant "${DEFAULT_AITENANT_NAME}" -n "${AITENANT_NAMESPACE}" \
    -o jsonpath='phase={.status.phase} tenantNs={.status.tenantNamespace}{"\n"}{range .status.conditions[*]}{.type}={.status} reason={.reason} msg={.message}{"\n"}{end}' \
    2>/dev/null || echo 'not found'
}
_save_text "$_dest/summaries/tenant-readiness.txt" "default tenant readiness" \
  _tenant_readiness_text

_cluster_pressure_text() {
  _k get nodes -o wide 2>/dev/null || true
  echo ''
  _k get pods -A --field-selector=status.phase=Pending -o wide 2>/dev/null || true
  echo ''
  _k get pods -A | grep -E 'CrashLoop|OOM|Error' 2>/dev/null || true
}
_save_text "$_dest/summaries/cluster-pressure.txt" "cluster pressure" \
  _cluster_pressure_text

# --- priority CRs (full YAML) ---
_save_yaml "$_dest/crs/maastenantconfig-default-tenant.yaml" \
  maastenantconfig "${DEFAULT_TENANT_CONFIG_NAME}" -n "$MAAS_SUBSCRIPTION_NAMESPACE"
_save_yaml "$_dest/crs/aitenant-models-as-a-service.yaml" \
  aitenant "${DEFAULT_AITENANT_NAME}" -n "$AITENANT_NAMESPACE"
_save_yaml "$_dest/crs/config-default.yaml" config.maas.opendatahub.io default

# Discover and dump every maas.opendatahub.io + inference.opendatahub.io kind (cluster-wide).
_collect_api_group_resources "maas.opendatahub.io" "crs/maas"
_collect_api_group_resources "inference.opendatahub.io" "crs/inference"
_collect_maas_inventory

# DataScienceCluster / DSCI (operator Managed flags for MaaS + aigateway).
_collect_dsc

# Gateway API HTTPRoutes/Gateways (oc adm must-gather omits these).
_collect_gateway_api
_collect_kuadrant_policies
_collect_istio_gateway_networking

for cr in \
  "llminferenceservices.serving.kserve.io:-A" \
  "aigateways.components.platform.opendatahub.io:-A" \
  "llmbatchgateways.batch.llm-d.ai:-A"; do
  kind="${cr%%:*}"
  args="${cr#*:}"
  # shellcheck disable=SC2086
  _save_yaml "$_dest/crs/${kind//./-}-all.yaml" "$kind" $args
done

# --- workloads ---
_save_yaml "$_dest/workloads/maas-controller-deployment.yaml" \
  deployment maas-controller -n "$DEPLOYMENT_NAMESPACE"
_save_yaml "$_dest/workloads/ai-gateway-controller-deployment.yaml" \
  deployment ai-gateway-controller -n "$DEPLOYMENT_NAMESPACE"
_save_yaml "$_dest/workloads/payload-processing-openshift-ingress.yaml" \
  deployment payload-processing -n "$GATEWAY_NAMESPACE"
_save_text "$_dest/workloads/maas-api-deployments.txt" "maas-api deployments" \
  _k get deploy -n "$MAAS_API_DEPLOYMENT_NAMESPACE" -l app.kubernetes.io/name=maas-api -o wide
_save_text "$_dest/workloads/gateway-namespace.txt" "gateway namespace workloads" \
  _k get deploy,pods,svc -n "$GATEWAY_NAMESPACE" -o wide
_save_text "$_dest/workloads/operator-namespace.txt" "RHOAI/ODH operator namespace" \
  _k get pods,deploy,csv -n "$OPERATOR_NAMESPACE" -o wide
_save_text "$_dest/workloads/applications-namespace.txt" "RHOAI/ODH applications namespace" \
  _k get pods,deploy,svc -n "$APPLICATIONS_NAMESPACE" -o wide

# --- events ---
for ns in \
  "$MAAS_SUBSCRIPTION_NAMESPACE" \
  "$AITENANT_NAMESPACE" \
  "$DEPLOYMENT_NAMESPACE" \
  "$MAAS_API_DEPLOYMENT_NAMESPACE" \
  "$GATEWAY_NAMESPACE" \
  "$LLM_NAMESPACE" \
  "$AUTHORINO_NAMESPACE" \
  "$OPERATOR_NAMESPACE" \
  "$APPLICATIONS_NAMESPACE" \
  "$ISTIO_NAMESPACE"; do
  if _k get namespace "$ns" &>/dev/null; then
    _save_events "$ns"
  fi
done

# --- worker / e2e tenant namespaces ---
_worker_tenant_namespaces_text() {
  _k get ns -o name 2>/dev/null | grep -E 'e2e-models-e2e-worker|e2e-worker' || true
}
_save_text "$_dest/worker-tenants/namespaces.txt" "e2e worker tenant namespaces" \
  _worker_tenant_namespaces_text
while IFS= read -r ns_line; do
  [[ -z "$ns_line" ]] && continue
  ns="${ns_line#namespace/}"
  _save_yaml "$_dest/worker-tenants/${ns}-maassubscriptions.yaml" \
    maassubscriptions.maas.opendatahub.io -n "$ns"
  _save_yaml "$_dest/worker-tenants/${ns}-maastenantconfig.yaml" \
    maastenantconfig -n "$ns" 2>/dev/null || true
  _save_yaml "$_dest/worker-tenants/${ns}-maasauthpolicies.yaml" \
    maasauthpolicies.maas.opendatahub.io -n "$ns" 2>/dev/null || true
  _save_yaml "$_dest/worker-tenants/${ns}-maasmodelrefs.yaml" \
    maasmodelrefs.maas.opendatahub.io -n "$ns" 2>/dev/null || true
  httproute_resource="$(_resolve_cluster_resource httproute \
    httproutes.gateway.networking.k8s.io httproute.gateway.networking.k8s.io httproutes httproute || true)"
  if [[ -n "${httproute_resource}" ]]; then
    _save_yaml "$_dest/worker-tenants/${ns}-httproutes.yaml" "${httproute_resource}" -n "$ns"
  fi
  _save_events "$ns"
done < <(_k get ns -o name 2>/dev/null | grep -E 'e2e-models-e2e-worker|e2e-worker' || true)

# --- controller logs (filtered + tail) ---
_save_pod_logs_grep "$DEPLOYMENT_NAMESPACE" "app=maas-controller" \
  'default-tenant|models-as-a-service|TenantConfig|tenant.*ready|error|fail' \
  "$_dest/logs/maas-controller-tenant.log"
_save_pod_logs_grep "$DEPLOYMENT_NAMESPACE" "app.kubernetes.io/name=ai-gateway-controller" \
  'models-as-a-service|praxis|finalizer|error|fail' \
  "$_dest/logs/ai-gateway-controller-tenant.log"
_save_pod_logs_grep "$GATEWAY_NAMESPACE" "app=payload-processing" \
  'error|fail|warn' \
  "$_dest/logs/payload-processing.log"

_log "=== MaaS must-gather finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
echo "MaaS diagnostics written to ${_dest}"
