#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
SUITE=${E2E_SUITE:-all}
if [[ "${1:-}" == "--suite" ]]; then
  SUITE=${2:?--suite requires routing, transition, or all}
  shift 2
fi
case "$SUITE" in
  routing|transition|all) ;;
  *) echo "invalid suite: $SUITE (expected routing, transition, or all)" >&2; exit 2 ;;
esac
export E2E_SUITE="$SUITE"
CLUSTER=${LOCAL_ENV_CLUSTER:-external-model-two-plane}
NS=${LOCAL_ENV_NAMESPACE:-models-as-a-service}
BNS=${LOCAL_ENV_TENANT_B_NAMESPACE:-ai-tenant-tenant-b}
API_NS=${LOCAL_ENV_API_NAMESPACE:-maas-system}
GATEWAY_NS=${LOCAL_ENV_GATEWAY_NAMESPACE:-maas-system}
KCTL=(kubectl --context "kind-$CLUSTER")
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
EVIDENCE=${LOCAL_ENV_EVIDENCE:-"$ROOT/evidence/$STAMP-e2e"}
PORT=${LOCAL_ENV_PORT:-$((18080 + ($$ % 1000)))}
API_PORT=$((PORT + 1))
BPORT=$((PORT + 2))
TPORT=$((PORT + 3))
PROVIDER_PORT=$((PORT + 5))
mkdir -p "$EVIDENCE"
exec > >(tee "$EVIDENCE/e2e.log") 2>&1
RECOMPUTE_BIN="$EVIDENCE/recompute-digest"
go build -o "$RECOMPUTE_BIN" "$ROOT/test/kind-env/recompute_digest.go"

QUALIFICATION_COMPLETE=false
finish_on_exit() {
  local rc=$?
  kill "${PF:-}" "${BPF:-}" "${APF:-}" "${TPF:-}" "${TAPF:-}" "${PROVIDER_PF:-}" 2>/dev/null || true
  rm -f "${AUTH_HEADER_FILE:-}" "${TRANSITION_AUTH_HEADER_FILE:-}"
  if [[ "$QUALIFICATION_COMPLETE" != true && -f "$EVIDENCE/results.json" ]]; then
    python3 - "$EVIDENCE/results.json" "$rc" <<'PY'
import json, os, sys, tempfile
p, rc = sys.argv[1:]
try:
    d = json.load(open(p))
except (OSError, ValueError):
    d = {"assertions": [], "requests": [], "phases": []}
d["status"] = "INTERRUPTED" if int(rc) in (130, 143) else "FAIL"
d["exit_code"] = int(rc)
fd, tmp = tempfile.mkstemp(prefix=".results.", dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, p)
PY
  fi
  return "$rc"
}
trap finish_on_exit EXIT

python3 - "$EVIDENCE/results.json" <<'PY'
import json, os, sys, tempfile
p = sys.argv[1]
fd, tmp = tempfile.mkstemp(prefix=".results.", dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump({"status":"RUNNING","assertions":[],"requests":[],"phases":[]}, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, p)
PY

record() {
  local n=$1 name=$2 status=$3 http=${4:-null} body=${5:-}
  python3 - "$EVIDENCE/results.json" "$n" "$name" "$status" "$http" "$body" <<'PY'
import json, os, sys, tempfile
p,n,name,status,http,body=sys.argv[1:]
d=json.load(open(p))
d["assertions"].append({"number":int(n),"name":name,"suite":os.environ.get("E2E_SUITE","all"),"status":status,"http_status":None if http=="null" else int(http),"body":body})
fd, tmp = tempfile.mkstemp(prefix=".results.", dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, p)
PY
}

# kubectl auth can-i returns exit status 1 for a valid, negative answer. Keep
# that answer instead of treating it as a command failure and appending an
# unrelated "unknown" marker.
auth_can_i() {
  local output
  output=$("${KCTL[@]}" auth can-i "$@" 2>/dev/null || true)
  printf '%s\n' "${output%%$'\n'*}"
}

observe() {
  local phase=$1
  "${KCTL[@]}" -n "$NS" get externalprovider,externalmodel,httproute,serviceentry,destinationrule,configmap,pod -o json >"$EVIDENCE/$phase-state.json" 2>&1 || true
  "${KCTL[@]}" -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].metadata.uid} {.items[0].status.containerStatuses[0].restartCount}' >"$EVIDENCE/$phase-praxis.txt" 2>&1 || true
}

wait_mounted_digest() {
  local expected=$1 actual stable=0
  # ConfigMap projection is eventually consistent; allow a bounded window
  # longer than kubelet's normal sync period and verify the mounted bytes.
  for _ in $(seq 1 60); do
    "${KCTL[@]}" -n "$NS" exec deploy/praxis -- cat /etc/praxis/routing/routing-overlay.json >"$EVIDENCE/mounted-overlay.json" 2>/dev/null || true
    actual=$("$RECOMPUTE_BIN" "$EVIDENCE/mounted-overlay.json" 2>/dev/null || true)
    if [[ "$actual" == "$expected" ]]; then
      stable=$((stable + 1))
      [[ $stable -ge 2 ]] && return 0
    else
      stable=0
    fi
    sleep 2
  done
  return 1
}

wait_transport() {
  local provider=$1
  for _ in $(seq 1 60); do
    if "${KCTL[@]}" -n "$NS" get \
      "service/provider-provider-$provider" \
      "serviceentry/provider-provider-$provider" \
      "destinationrule/provider-provider-$provider" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

ca_matches_live_maas_certificate() {
  local candidate=$1 live_certificate
  live_certificate=$(mktemp)
  if ! "${KCTL[@]}" -n "$API_NS" get secret maas-api-serving-cert \
    -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 --decode >"$live_certificate"; then
    rm -f "$live_certificate"
    return 1
  fi
  if ! openssl verify -CAfile "$candidate" \
    -verify_hostname maas-api.maas-system.svc.cluster.local \
    "$live_certificate" >/dev/null 2>&1; then
    rm -f "$live_certificate"
    return 1
  fi
  rm -f "$live_certificate"
  return 0
}

resolve_maas_api_ca() {
  local active_run_file=${LOCAL_ENV_ACTIVE_RUN_FILE:-${LOCAL_ENV_EVIDENCE_ROOT:-$ROOT/evidence}/.active-run}
  local run_root candidate
  if [[ -s "$active_run_file" ]]; then
    run_root=$(<"$active_run_file")
    candidate="$run_root/maas-api-ca.crt"
    if [[ -s "$candidate" ]] && ca_matches_live_maas_certificate "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  fi

  # A retained cluster may outlive the evidence pointer from a prior run.
  # Select the newest candidate that verifies against the live serving cert;
  # never trust path recency or an unverified stale pointer by itself.
  while IFS= read -r candidate; do
    if ca_matches_live_maas_certificate "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "${LOCAL_ENV_EVIDENCE_ROOT:-$ROOT/evidence}" -type f \
    -name maas-api-ca.crt -print 2>/dev/null | sort -r)
  return 1
}

wait_stable_overlay() {
  local first second
  for _ in $(seq 1 60); do
    first=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o json 2>/dev/null \
      | jq -c '{data,annotations:{source:.metadata.annotations["inference.opendatahub.io/routing-overlay-source-generation"],digest:.metadata.annotations["inference.opendatahub.io/routing-overlay-content-digest"]}}' || true)
    sleep 2
    second=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o json 2>/dev/null \
      | jq -c '{data,annotations:{source:.metadata.annotations["inference.opendatahub.io/routing-overlay-source-generation"],digest:.metadata.annotations["inference.opendatahub.io/routing-overlay-content-digest"]}}' || true)
    [[ -n "$first" && "$first" == "$second" ]] && return 0
  done
  return 1
}

wait_provider_baseline() {
  local expected=$1 stable=0 candidates observed generation digest mounted
  for _ in $(seq 1 60); do
    candidates=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' 2>/dev/null || true)
    observed=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
    generation=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
    digest=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
    mounted=$("${KCTL[@]}" -n "$NS" exec deploy/praxis -- cat /etc/praxis/routing/routing-overlay.json 2>/dev/null | "$RECOMPUTE_BIN" /dev/stdin 2>/dev/null || true)
    if [[ "$candidates" == *"provider-provider-$expected"* && "$candidates" != *'provider-provider-b'* && "$observed" == "$generation" && "$digest" =~ ^[0-9a-f]{64}$ && "$mounted" == "$digest" ]] && "${KCTL[@]}" -n "$NS" get service/provider-provider-"$expected" serviceentry/provider-provider-"$expected" destinationrule/provider-provider-"$expected" >/dev/null 2>&1; then
      stable=$((stable + 1))
      [[ $stable -ge 2 ]] && return 0
    else
      stable=0
    fi
    sleep 2
  done
  return 1
}

wait_transition_gateway_data_plane() {
  local route_fragment=$1 backend_fragment=$2 stable=0 gateway_pod dump clusters
  # Gateway API status is control-plane evidence only. Require the actual
  # transition route and backend cluster in the Gateway Envoy snapshot before
  # sending a request; otherwise a cold xDS update can be mistaken for a
  # routing or ownership failure.
  for _ in $(seq 1 60); do
    gateway_pod=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get pods \
      -l gateway.networking.k8s.io/gateway-name=maas-transition-gateway \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    dump=""
    clusters=""
    if [[ -n "$gateway_pod" ]]; then
      dump=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" exec "$gateway_pod" -c istio-proxy -- \
        curl -fsS http://127.0.0.1:15000/config_dump 2>/dev/null || true)
      clusters=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" exec "$gateway_pod" -c istio-proxy -- \
        curl -fsS http://127.0.0.1:15000/clusters 2>/dev/null || true)
    fi
    if [[ "$dump" == *"$route_fragment"* && "$dump" == *"$backend_fragment"* && \
          "$clusters" == *"$backend_fragment"* && "$clusters" == *"health_flags::healthy"* ]]; then
      stable=$((stable + 1))
      [[ $stable -ge 2 ]] && return 0
    else
      stable=0
    fi
    sleep 2
  done
  return 1
}

wait_transition_writer_data_plane() {
  local stable=0 processing_ready preprocessing_ready processing_endpoints preprocessing_endpoints
  for _ in $(seq 1 60); do
    processing_ready=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get deployment/payload-processing-transition -o json 2>/dev/null \
      | jq -r '(.spec.replicas // 0) > 0 and (.status.readyReplicas // 0) == (.spec.replicas // 0) and (.status.updatedReplicas // 0) == (.spec.replicas // 0)' || echo false)
    preprocessing_ready=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get deployment/payload-pre-processing-transition -o json 2>/dev/null \
      | jq -r '(.spec.replicas // 0) > 0 and (.status.readyReplicas // 0) == (.spec.replicas // 0) and (.status.updatedReplicas // 0) == (.spec.replicas // 0)' || echo false)
    processing_endpoints=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get endpointslice -l kubernetes.io/service-name=payload-processing-transition -o json 2>/dev/null \
      | jq -r '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' || echo 0)
    preprocessing_endpoints=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get endpointslice -l kubernetes.io/service-name=payload-pre-processing-transition -o json 2>/dev/null \
      | jq -r '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' || echo 0)
    if [[ "$processing_ready" == true && "$preprocessing_ready" == true && "$processing_endpoints" -gt 0 && "$preprocessing_endpoints" -gt 0 ]]; then
      stable=$((stable + 1))
      [[ $stable -ge 2 ]] && return 0
    else
      stable=0
    fi
    sleep 2
  done
  return 1
}

wait_transition_praxis_data_plane() {
  local stable=0 deployment_ready service_endpoints
  for _ in $(seq 1 60); do
    deployment_ready=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get deployment/"$TRANSITION_PRAXIS_NAME" -o json 2>/dev/null \
      | jq -r '(.spec.replicas // 0) > 0 and (.status.readyReplicas // 0) == (.spec.replicas // 0) and (.status.updatedReplicas // 0) == (.spec.replicas // 0)' || echo false)
    service_endpoints=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get endpointslice -l kubernetes.io/service-name="$TRANSITION_PRAXIS_NAME" -o json 2>/dev/null \
      | jq -r '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' || echo 0)
    if [[ "$deployment_ready" == true && "$service_endpoints" -gt 0 ]]; then
      stable=$((stable + 1))
      [[ $stable -ge 2 ]] && return 0
    else
      stable=0
    fi
    sleep 2
  done
  return 1
}

"${KCTL[@]}" cluster-info >"$EVIDENCE/cluster-info.txt" 2>&1 || exit 2
if [[ "$SUITE" != transition ]]; then
# Keep the run-owned ExternalModel object and its UID across same-cluster
# repeats. Recreating it changes overlay provenance even when the requested
# route is semantically identical. The fixture apply below resets its
# declarative spec, and the explicit Provider-A patch establishes the baseline.
# Remove only the controller-owned routing snapshot before reconciling the
# fixture so prior projected bytes cannot be mistaken for the new baseline.
if [[ "$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)" == ai-gateway-controller ]]; then
  "${KCTL[@]}" -n "$NS" delete configmap routing-overlay --wait=true >/dev/null
fi
# MaaS may reconcile its generated IPP Deployments while the baseline model is
# recreated. Re-assert the run-owned transition fixture after that event. Do
# not delete existing IPP routes here: their owner is the pinned IPP
# ExternalModel reconciler, and deleting them would hide a cutover defect.
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-processing >/dev/null 2>&1; then
  "${KCTL[@]}" -n "$API_NS" set env deployment/payload-processing \
    NAMESPACE=models-as-a-service TENANT_NAMESPACE=models-as-a-service GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-default-gateway DISABLE_EXTERNAL_MODEL_CONTROLLER=true >/dev/null
fi
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-processing-tenant-b >/dev/null 2>&1; then
  "${KCTL[@]}" -n "$API_NS" set env deployment/payload-processing-tenant-b \
    NAMESPACE=ai-tenant-tenant-b TENANT_NAMESPACE=ai-tenant-tenant-b GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-tenant-b-gateway DISABLE_EXTERNAL_MODEL_CONTROLLER=true >/dev/null
fi
"${KCTL[@]}" -n "$API_NS" set env deployment/payload-processing-transition \
  NAMESPACE=ai-tenant-transition TENANT_NAMESPACE=ai-tenant-transition GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-transition-gateway DISABLE_EXTERNAL_MODEL_CONTROLLER=false >/dev/null
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-pre-processing >/dev/null 2>&1; then
  "${KCTL[@]}" -n "$API_NS" set env deployment/payload-pre-processing \
    NAMESPACE=models-as-a-service TENANT_NAMESPACE=models-as-a-service GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-default-gateway DISABLE_EXTERNAL_MODEL_CONTROLLER=true >/dev/null
fi
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-pre-processing-tenant-b >/dev/null 2>&1; then
  "${KCTL[@]}" -n "$API_NS" set env deployment/payload-pre-processing-tenant-b \
    NAMESPACE=ai-tenant-tenant-b TENANT_NAMESPACE=ai-tenant-tenant-b GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-tenant-b-gateway DISABLE_EXTERNAL_MODEL_CONTROLLER=true >/dev/null
fi
"${KCTL[@]}" -n "$API_NS" set env deployment/payload-pre-processing-transition \
  NAMESPACE=ai-tenant-transition TENANT_NAMESPACE=ai-tenant-transition GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-transition-gateway DISABLE_EXTERNAL_MODEL_CONTROLLER=false >/dev/null
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-processing >/dev/null 2>&1; then "${KCTL[@]}" -n "$API_NS" rollout status deployment/payload-processing --timeout=120s; fi
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-processing-tenant-b >/dev/null 2>&1; then "${KCTL[@]}" -n "$API_NS" rollout status deployment/payload-processing-tenant-b --timeout=120s; fi
"${KCTL[@]}" -n "$API_NS" rollout status deployment/payload-processing-transition --timeout=120s
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-pre-processing >/dev/null 2>&1; then "${KCTL[@]}" -n "$API_NS" rollout status deployment/payload-pre-processing --timeout=120s; fi
if "${KCTL[@]}" -n "$API_NS" get deployment/payload-pre-processing-tenant-b >/dev/null 2>&1; then "${KCTL[@]}" -n "$API_NS" rollout status deployment/payload-pre-processing-tenant-b --timeout=120s; fi
"${KCTL[@]}" -n "$API_NS" rollout status deployment/payload-pre-processing-transition --timeout=120s
# Recreate the Praxis tenant model only after its IPP writer has restarted with
# external-model reconciliation disabled. This prevents a direct IPP route
# from being created during qualification setup.
"${KCTL[@]}" apply -f "$ROOT/test/kind-env/manifests/20-fixtures.yaml" >/dev/null
for _ in $(seq 1 30); do
  phase=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$phase" == Ready ]] && break
  sleep 2
done
[[ "$phase" == Ready ]] || { echo "baseline ExternalModel did not become Ready" >&2; exit 1; }
# Establish a deterministic baseline route through backend A. The production
# resolver is still round-robin in this branch; the phase transition is used
# only to make the transport-chain assertion attributable.
"${KCTL[@]}" -n "$NS" patch externalmodel demo-model --type=json -p='[{"op":"replace","path":"/spec/externalProviderRefs","value":[{"ref":{"name":"provider-a"},"targetModel":"demo","apiFormat":"openai-chat","path":"/v1/chat/completions"}]}]' >/dev/null
for _ in $(seq 1 30); do
  candidates=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' 2>/dev/null || true)
  observed_model_gen=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
  model_gen=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
  phase=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.phase}' 2>/dev/null || true)
  ref=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.spec.externalProviderRefs[0].ref.name}' 2>/dev/null || true)
  [[ "$phase" == Ready && "$ref" == provider-a && "$candidates" == *'provider-provider-a'* && "$candidates" != *'provider-provider-b'* && "$observed_model_gen" == "$model_gen" ]] && break
  sleep 2
done
[[ "$phase" == Ready && "$ref" == provider-a && "$candidates" == *'provider-provider-a'* && "$candidates" != *'provider-provider-b'* && "$observed_model_gen" == "$model_gen" ]] || { echo "baseline provider-A overlay did not converge" >&2; exit 1; }
wait_stable_overlay || { echo "baseline overlay did not stabilize" >&2; exit 1; }
# Publication and ExternalModel status are not sufficient to send traffic:
# the previous provider transport may still be deleting and kubelet may still
# be projecting the new snapshot into Praxis. Gate the first request on the
# complete state as two consecutive observations.
wait_provider_baseline a || { echo "baseline provider-A overlay, transport, and mounted snapshot did not converge together" >&2; exit 1; }
baseline_declared_digest=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
[[ "$baseline_declared_digest" =~ ^[0-9a-f]{64}$ ]] || { echo "baseline provider-A digest is empty or invalid: $baseline_declared_digest" >&2; exit 1; }
wait_mounted_digest "$baseline_declared_digest" || { echo "baseline provider-A overlay was not mounted" >&2; exit 1; }
if "${KCTL[@]}" get crd externalmodels.inference.opendatahub.io externalproviders.inference.opendatahub.io >/dev/null 2>&1; then record 1 crds_ready PASS; else record 1 crds_ready FAIL; fi
observe baseline
base_generation=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-source-generation}' 2>/dev/null || echo 0)
base_digest=""
baseline_recompute=""
for _ in $(seq 1 60); do
  base_digest=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
  "${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' >"$EVIDENCE/baseline-overlay.json" 2>/dev/null || true
  baseline_recompute=$("$RECOMPUTE_BIN" "$EVIDENCE/baseline-overlay.json" 2>/dev/null || true)
  [[ "$base_digest" =~ ^[0-9a-f]{64}$ && "$baseline_recompute" == "$base_digest" ]] && break
  sleep 2
done
if [[ "$base_digest" =~ ^[0-9a-f]{64}$ && "$baseline_recompute" == "$base_digest" ]]; then
  record 8 digest_and_revision PASS null "declared=$base_digest recomputed=$baseline_recompute"
else
  record 8 digest_and_revision FAIL null "declared=$base_digest recomputed=$baseline_recompute"
fi
if "${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.phase}' | rg -qx Ready; then record 2 real_cr_reconciliation PASS; else record 2 real_cr_reconciliation FAIL; fi
if "${KCTL[@]}" -n "$NS" get httproute/external-model-demo-model serviceentries/provider-provider-a destinationrules/provider-provider-a >/dev/null 2>&1; then record 3 transport_resources PASS; else record 3 transport_resources FAIL; fi
route_status=$("${KCTL[@]}" -n "$NS" get httproute external-model-demo-model -o json 2>/dev/null || echo '{}')
if jq -e '[.status.parents[]?.conditions[]? | select((.type=="Accepted" or .type=="ResolvedRefs" or .type=="kuadrant.io/AuthPolicyAffected") and .status=="True")] | length >= 2' <<<"$route_status" >/dev/null; then record 4 httproute_status PASS; else record 4 httproute_status FAIL null "$(jq -c '.status.parents // []' <<<"$route_status")"; fi

# Namespace-boundary proof: the route lives with the resolved tenant and uses
# a cross-namespace Gateway parent. Its backend is intentionally same-namespace
# (the tenant Praxis Service), so Gateway API ReferenceGrant is not required for
# this path. The Gateway listener's allowedRoutes policy is captured alongside
# the route status; no broad Secret API access is granted to either Praxis pod.
boundary_route=$("${KCTL[@]}" -n "$NS" get httproute external-model-demo-model -o json 2>/dev/null || echo '{}')
boundary_gateway=$("${KCTL[@]}" -n "$GATEWAY_NS" get gateway maas-default-gateway -o json 2>/dev/null || echo '{}')
boundary_grants=$("${KCTL[@]}" get referencegrant -A -o json 2>/dev/null || echo '{"items":[]}')
boundary_sa_a=$(auth_can_i get secrets --as="system:serviceaccount:$NS:praxis" -n "$NS")
printf '%s\n' "$boundary_route" >"$EVIDENCE/namespace-boundary-route.json"
printf '%s\n' "$boundary_gateway" >"$EVIDENCE/namespace-boundary-gateway.json"
printf '%s\n' "$boundary_grants" >"$EVIDENCE/namespace-boundary-referencegrants.json"
printf 'tenant_namespace=%s gateway_namespace=%s backend_namespace=%s praxis_a_secret_api=%s referencegrant_count=%s\n' \
  "$NS" "$GATEWAY_NS" \
  "$(jq -r '.spec.rules[0].backendRefs[0].namespace // .metadata.namespace // ""' <<<"$boundary_route")" \
  "$boundary_sa_a" "$(jq '.items | length' <<<"$boundary_grants")" >"$EVIDENCE/namespace-boundary-state.txt"
route_parent_ns=$(jq -r '.spec.parentRefs[0].namespace // .metadata.namespace // ""' <<<"$boundary_route")
route_backend_ns=$(jq -r '.spec.rules[0].backendRefs[0].namespace // .metadata.namespace // ""' <<<"$boundary_route")
route_accepted=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length' <<<"$boundary_route")
route_refs=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length' <<<"$boundary_route")
gateway_from=$(jq -r '.spec.listeners[0].allowedRoutes.namespaces.from // ""' <<<"$boundary_gateway")
gateway_selector=$(jq -r '.spec.listeners[0].allowedRoutes.namespaces.selector.matchLabels["local-env.opendatahub.io/gateway-tenant"] // ""' <<<"$boundary_gateway")
boundary_namespace_label=$("${KCTL[@]}" get namespace "$NS" -o jsonpath='{.metadata.labels.local-env\.opendatahub\.io/gateway-tenant}' 2>/dev/null || true)
boundary_failures=()
[[ "$route_parent_ns" == "$GATEWAY_NS" ]] || boundary_failures+=("parent_namespace expected=$GATEWAY_NS actual=$route_parent_ns")
[[ "$route_backend_ns" == "$NS" ]] || boundary_failures+=("backend_namespace expected=$NS actual=$route_backend_ns")
[[ "$route_accepted" =~ ^[1-9][0-9]*$ ]] || boundary_failures+=("accepted expected=true actual_count=$route_accepted")
[[ "$route_refs" =~ ^[1-9][0-9]*$ ]] || boundary_failures+=("resolved_refs expected=true actual_count=$route_refs")
[[ "$gateway_from" == "Selector" ]] || boundary_failures+=("allowed_routes expected=Selector actual=$gateway_from")
[[ "$gateway_selector" == "$NS" ]] || boundary_failures+=("gateway_selector expected=$NS actual=$gateway_selector")
[[ "$boundary_namespace_label" == "$NS" ]] || boundary_failures+=("namespace_gateway_label expected=$NS actual=$boundary_namespace_label")
[[ "$boundary_sa_a" == "no" ]] || boundary_failures+=("secret_api expected=denied actual=$boundary_sa_a")
[[ "$(jq '.items | length' <<<"$boundary_grants")" == 0 ]] || boundary_failures+=("referencegrant_count expected=0 actual=$(jq '.items | length' <<<"$boundary_grants")")
if [[ "${#boundary_failures[@]}" == 0 ]]; then
  record 28 namespace_boundary_route_and_secret_isolation PASS null "tenant_namespace=$NS gateway_namespace=$GATEWAY_NS backend_namespace=$NS referencegrant_required=false praxis_secret_api=denied"
else
  (IFS='; '; record 28 namespace_boundary_route_and_secret_isolation FAIL null "$(cat "$EVIDENCE/namespace-boundary-state.txt") mismatches=${boundary_failures[*]}")
fi

"${KCTL[@]}" -n "$API_NS" port-forward svc/maas-api "$API_PORT:8443" >"$EVIDENCE/maas-api-port-forward.log" 2>&1 &
APF=$!
for _ in $(seq 1 20); do
  rg -q 'Forwarding from' "$EVIDENCE/maas-api-port-forward.log" && break
  sleep 1
done
ACTIVE_RUN_FILE="${LOCAL_ENV_ACTIVE_RUN_FILE:-${LOCAL_ENV_EVIDENCE_ROOT:-$ROOT/evidence}/.active-run}"
CA_CERT=""
if ! CA_CERT=$(resolve_maas_api_ca); then
  record 16 verified_maas_api_tls FAIL null "no CA certificate verified against the live MaaS API serving certificate; active_run_file=$ACTIVE_RUN_FILE"
  exit 1
fi
printf 'ca_source=%s\nca_sha256=%s\nverified_hostname=maas-api.maas-system.svc.cluster.local\n' \
  "$CA_CERT" "$(sha256sum "$CA_CERT" | awk '{print $1}')" >"$EVIDENCE/maas-api-ca-selection.txt"
if ! key_response=$(timeout 15s curl --noproxy '*' --cacert "$CA_CERT" --resolve "maas-api.maas-system.svc.cluster.local:$API_PORT:127.0.0.1" -sS -H 'content-type: application/json' -H 'X-MaaS-Username: kind-user' -H 'X-MaaS-Group: ["system:authenticated"]' --data '{"name":"kind-e2e","ephemeral":true,"subscription":"kind-e2e-subscription"}' "https://maas-api.maas-system.svc.cluster.local:$API_PORT/v1/api-keys"); then
  record 16 verified_maas_api_tls FAIL null "verified HTTPS request failed"
  exit 1
fi
if ! key=$(jq -er '.key' <<<"$key_response"); then
  record 16 verified_maas_api_tls FAIL null "verified HTTPS response did not contain an API key"
  exit 1
fi
unset key_response
AUTH_HEADER_FILE="$EVIDENCE/.auth-header"
umask 077
printf 'Authorization: Bearer %s\n' "$key" >"$AUTH_HEADER_FILE"
unset key
record 16 verified_maas_api_tls PASS null "verification=enabled ca=$(sha256sum "$CA_CERT" | awk '{print $1}') certificate=$(dirname "$CA_CERT")/maas-api-serving-certificate.txt"
"${KCTL[@]}" -n "$GATEWAY_NS" port-forward svc/maas-default-gateway-istio "$PORT:80" >"$EVIDENCE/port-forward.log" 2>&1 &
PF=$!
for _ in $(seq 1 20); do
  rg -q 'Forwarding from' "$EVIDENCE/port-forward.log" && break
  sleep 1
done
request() { timeout 15s curl -sS -D "$EVIDENCE/request-$1.headers" -o "$EVIDENCE/request-$1.body" -w '%{http_code}' "$2" "${@:3}" -H "@${REQUEST_AUTH_HEADER_FILE:-$AUTH_HEADER_FILE}" || echo 000; }
redact_provider_response() {
  local file=$1
  [[ -f "$file" ]] || return 0
  sed -E -i \
    -e "s/(got|expected)[[:space:]]+'[^']*'/\\1 '[REDACTED]'/g" \
    -e 's/(Bearer[[:space:]]+)[^[:space:]"}]*/\\1[REDACTED]/g' \
    "$file"
}
BASE_URL="http://127.0.0.1:$PORT"
MODEL_URL="$BASE_URL/$NS/demo/v1/chat/completions"
unauth=$(REQUEST_AUTH_HEADER_FILE=/dev/null request unauth "$MODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"unauthenticated"}]}' )
if [[ "$unauth" == 401 ]]; then record 5 unauthenticated_rejected PASS "$unauth" "$(cat "$EVIDENCE/request-unauth.body" 2>/dev/null || true)"; else record 5 unauthenticated_rejected FAIL "$unauth"; fi
callback_since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
known=$(request known "$MODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"hello"}]}' )
: >"$EVIDENCE/maas-callbacks-after-known.log"
callback_validate=0
callback_select=0
for _ in $(seq 1 10); do
  "${KCTL[@]}" -n "$API_NS" logs deployment/maas-api --since-time="$callback_since" 2>/dev/null \
    | rg '(/internal/v1/api-keys/validate|/internal/v1/subscriptions/select)' \
    | sed -E 's/"(auth_headers|keyPrefix|keyId|token|secret)":"[^"]*"/"\1":"[REDACTED]"/gI' \
    >"$EVIDENCE/maas-callbacks-after-known.log" || true
  callback_validate=$(rg -c '/internal/v1/api-keys/validate' "$EVIDENCE/maas-callbacks-after-known.log" 2>/dev/null || true)
  callback_select=$(rg -c '/internal/v1/subscriptions/select' "$EVIDENCE/maas-callbacks-after-known.log" 2>/dev/null || true)
  callback_validate=${callback_validate:-0}
  callback_select=${callback_select:-0}
  [[ "$callback_validate" -ge 1 && "$callback_select" -ge 1 ]] && break
  sleep 1
done
if [[ "$known" == 200 && "$callback_validate" -ge 1 ]]; then
  record 30 maas_api_key_validation_callback_observed PASS "$known" "callback_count=$callback_validate evidence=maas-callbacks-after-known.log"
elif [[ "$known" == 200 ]]; then
  record 30 maas_api_key_validation_callback_observed NOT_DEMONSTRATED "$known" "request_succeeded=true callback_observed=false evidence=maas-callbacks-after-known.log"
else
  record 30 maas_api_key_validation_callback_observed FAIL "$known" "callback_count=$callback_validate evidence=maas-callbacks-after-known.log"
fi
authpolicy_json=$("${KCTL[@]}" -n "$NS" get authpolicy external-model-auth -o json 2>/dev/null || echo '{}')
if jq -e '.. | strings | select(test("/internal/v1/subscriptions/select"))' <<<"$authpolicy_json" >/dev/null 2>&1; then
  if [[ "$known" == 200 && "$callback_select" -ge 1 ]]; then
    record 31 maas_subscription_selection_callback_observed PASS "$known" "callback_count=$callback_select evidence=maas-callbacks-after-known.log"
  else
    record 31 maas_subscription_selection_callback_observed FAIL "$known" "policy_requires_callback=true callback_count=$callback_select evidence=maas-callbacks-after-known.log"
  fi
else
  python3 - "$EVIDENCE/results.json" <<'PY'
import json
import os
import sys
import tempfile

p = sys.argv[1]
d = json.load(open(p))
d.setdefault("not_demonstrated", []).append({
    "id": "maas_subscription_selection_callback",
    "reason": "generated AuthPolicy does not require /internal/v1/subscriptions/select",
})
fd, tmp = tempfile.mkstemp(prefix=".results.", dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, p)
PY
fi
if [[ "$known" == 200 ]] && rg -q 'server: istio-envoy' "$EVIDENCE/request-known.headers" && rg -q 'via: 1.1 praxis' "$EVIDENCE/request-known.headers"; then record 6 envoy_kuadrant_extproc_praxis_chain PASS "$known" "$(cat "$EVIDENCE/request-known.body" 2>/dev/null || true)"; else record 6 envoy_kuadrant_extproc_praxis_chain FAIL "$known" "$(cat "$EVIDENCE/request-known.headers" 2>/dev/null || true)"; fi
if [[ "$known" == 200 ]] && rg -q 'katan-a' "$EVIDENCE/request-known.body"; then record 7 backend_a PASS "$known"; else record 7 backend_a FAIL "$known"; fi
# Port-forward the run-owned provider directly so the credential-enforcing
# fixture is tested independently of Gateway/Authorino. These probes use no
# MaaS credential and an incorrect provider credential respectively; neither
# may reach the echo backend.
"${KCTL[@]}" -n "$API_NS" port-forward service/provider-a "$PROVIDER_PORT:8000" >"$EVIDENCE/provider-a-port-forward.log" 2>&1 &
PROVIDER_PF=$!
for _ in $(seq 1 20); do
  rg -q 'Forwarding from' "$EVIDENCE/provider-a-port-forward.log" && break
  sleep 1
done
provider_url="http://127.0.0.1:$PROVIDER_PORT/v1/chat/completions"
provider_body='{"model":"demo","messages":[{"role":"user","content":"credential-probe"}]}'
provider_missing_tmp=$(mktemp)
provider_missing=$(timeout 15s curl --noproxy '*' -sS -D "$EVIDENCE/provider-missing.headers" -o "$provider_missing_tmp" -w '%{http_code}' -H 'content-type: application/json' --data "$provider_body" "$provider_url" || echo 000)
cp "$provider_missing_tmp" "$EVIDENCE/provider-missing.body"
redact_provider_response "$EVIDENCE/provider-missing.body"
rm -f "$provider_missing_tmp"
if [[ "$provider_missing" == 401 ]]; then record 32 provider_rejects_missing_credential PASS "$provider_missing"; else record 32 provider_rejects_missing_credential FAIL "$provider_missing"; fi
provider_wrong_tmp=$(mktemp)
provider_wrong=$(timeout 15s curl --noproxy '*' -sS -D "$EVIDENCE/provider-wrong.headers" -o "$provider_wrong_tmp" -w '%{http_code}' -H 'content-type: application/json' -H 'Authorization: Bearer client-override' --data "$provider_body" "$provider_url" || echo 000)
cp "$provider_wrong_tmp" "$EVIDENCE/provider-wrong.body"
redact_provider_response "$EVIDENCE/provider-wrong.body"
rm -f "$provider_wrong_tmp"
if [[ "$provider_wrong" == 401 ]]; then record 33 provider_rejects_wrong_credential PASS "$provider_wrong"; else record 33 provider_rejects_wrong_credential FAIL "$provider_wrong"; fi
# The authenticated Gateway request carries the MaaS API key in Authorization,
# while Katan accepts only the distinct projected provider credential. Its
# attributed HTTP 200 therefore proves Praxis replaced the caller credential.
# Duplicate Authorization header ordering is intentionally outside this claim.
if [[ "$known" == 200 ]] && rg -q 'katan-a' "$EVIDENCE/request-known.body"; then
  record 34 client_authorization_cannot_override_provider_credential PASS "$known" "caller MaaS Authorization was replaced by the distinct projected provider credential; duplicate Authorization headers are out of scope"
else
  record 34 client_authorization_cannot_override_provider_credential FAIL "$known" "authenticated request did not reach the credential-enforcing Provider A backend"
fi
client_api_key_override=$(request client-api-key-override "$MODEL_URL" -H 'content-type: application/json' -H 'x-api-key: client-override' --data "$provider_body")
redact_provider_response "$EVIDENCE/request-client-api-key-override.body"
if [[ "$client_api_key_override" == 200 ]] && rg -q 'katan-a' "$EVIDENCE/request-client-api-key-override.body"; then record 35 client_x_api_key_cannot_override_provider_credential PASS "$client_api_key_override"; else record 35 client_x_api_key_cannot_override_provider_credential FAIL "$client_api_key_override"; fi
if [[ "$known" == 200 && "$provider_missing" == 401 && "$provider_wrong" == 401 && "$client_api_key_override" == 200 ]] && rg -q 'katan-a' "$EVIDENCE/request-known.body" && rg -q 'server: istio-envoy' "$EVIDENCE/request-known.headers" && rg -q 'via: 1.1 praxis' "$EVIDENCE/request-known.headers"; then
  record 36 credential_enforcing_provider_chain PASS "$known" "backend enforcement, caller Authorization replacement, and x-api-key resistance passed"
else
  record 36 credential_enforcing_provider_chain FAIL "$known" "gateway, backend credential, or x-api-key assertion failed"
fi

"${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' >"$EVIDENCE/baseline-overlay.json"
before_uid=$("${KCTL[@]}" -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].metadata.uid}')
before_restarts=$("${KCTL[@]}" -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
"${KCTL[@]}" -n "$NS" patch externalmodel demo-model --type=json -p='[{"op":"replace","path":"/spec/externalProviderRefs","value":[{"ref":{"name":"provider-b"},"targetModel":"demo","apiFormat":"openai-chat","path":"/v1/chat/completions"}]}]'
new_revision=""
for _ in $(seq 1 30); do
  new_revision=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-source-generation}' 2>/dev/null || true)
  [[ "$new_revision" == "$((base_generation + 1))" ]] && break
  sleep 2
done
changed_digest=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
changed_mounted=false
if wait_mounted_digest "$changed_digest"; then
  changed_mounted=true
fi
transport_ready=false
if wait_transport b; then
  transport_ready=true
fi
cp "$EVIDENCE/mounted-overlay.json" "$EVIDENCE/last-known-good-overlay.json"
  changed=$(request changed "$MODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"changed"}]}' )
changed_backend=$(rg -o 'katan-b-[A-Za-z0-9-]+' "$EVIDENCE/request-changed.body" | head -1 || true)
if [[ "$new_revision" == "$((base_generation + 1))" && "$changed_digest" =~ ^[0-9a-f]{64}$ && "$changed_mounted" == true && "$transport_ready" == true && "$changed" == 200 && -n "$changed_backend" ]]; then
  record 9 generation_two_swap_backend_b PASS "$changed" "generation=$new_revision digest=$changed_digest mounted=$changed_mounted transport=$transport_ready backend=$changed_backend"
else
  record 9 generation_two_swap_backend_b FAIL "$changed" "expected_generation=$((base_generation + 1)) observed_generation=$new_revision digest=$changed_digest mounted=$changed_mounted transport=$transport_ready backend=$changed_backend body=$(cat "$EVIDENCE/request-changed.body")"
fi
after_uid=$("${KCTL[@]}" -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].metadata.uid}')
after_restarts=$("${KCTL[@]}" -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
if [[ "$before_uid" == "$after_uid" && "$before_restarts" == "$after_restarts" ]]; then record 10 no_restart_during_swap PASS; else record 10 no_restart_during_swap FAIL; fi
unknown=$(request unknown "$MODEL_URL" -H 'content-type: application/json' --data '{"model":"missing","messages":[]}' )
if [[ "$unknown" == 404 ]]; then record 11 unknown_model_404 PASS "$unknown" "$(cat "$EVIDENCE/request-unknown.body")"; else record 11 unknown_model_404 FAIL "$unknown"; fi
"${KCTL[@]}" -n "$NS" get configmap routing-overlay -o json | jq '.data["routing-overlay.json"]="{}"' | "${KCTL[@]}" apply -f - >/dev/null
for _ in $(seq 1 15); do
  if "${KCTL[@]}" -n "$NS" logs deploy/praxis --since=1m 2>/dev/null | rg -q 'overlay reload failed, retaining previous snapshot'; then break; fi
  sleep 2
done
bad=$(request corrupted "$MODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"corrupted"}]}' )
if [[ "$bad" == 200 ]] && rg -q 'katan-b' "$EVIDENCE/request-corrupted.body"; then record 12 invalid_replacement_preserves_last_good PASS "$bad" "$(cat "$EVIDENCE/request-corrupted.body" 2>/dev/null || true)"; else record 12 invalid_replacement_preserves_last_good FAIL "$bad" "$(cat "$EVIDENCE/request-corrupted.body" 2>/dev/null || true)"; fi
# Leave the named environment healthy for the required idempotency and repeat
# runs. The corrupted replacement was already observed above; restore exactly
# the captured last-known-good bytes and retain the same revision annotations.
"${KCTL[@]}" -n "$NS" get configmap routing-overlay -o json | jq --rawfile data "$EVIDENCE/last-known-good-overlay.json" '.data["routing-overlay.json"]=$data' | "${KCTL[@]}" apply -f - >/dev/null
wait_stable_overlay || { record 12 invalid_replacement_preserves_last_good FAIL null "last-known-good overlay did not stabilize"; }
# A manual last-known-good restore must be followed by controller convergence;
# otherwise the restored data and metadata can describe different generations.
restored_digest=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
if [[ "$restored_digest" =~ ^[0-9a-f]{64}$ ]]; then
  wait_mounted_digest "$restored_digest" || { record 12 invalid_replacement_preserves_last_good FAIL null "last-known-good overlay was not remounted"; }
fi
for _ in $(seq 1 30); do
  overlay_state=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay -o json 2>/dev/null || echo '{}')
  embedded_source=$(jq -r '.data["routing-overlay.json"] // "{}"' <<<"$overlay_state" | jq -r '.provenance.source_generation // ""' 2>/dev/null || true)
  declared_source=$(jq -r '.metadata.annotations["inference.opendatahub.io/routing-overlay-source-generation"] // ""' <<<"$overlay_state")
  [[ -n "$embedded_source" && "$embedded_source" == "$declared_source" ]] && break
  sleep 2
done
observe changed
"${KCTL[@]}" -n "$NS" get configmap routing-overlay -o json | jq '{data, annotations: {source: .metadata.annotations["inference.opendatahub.io/routing-overlay-source-generation"], digest: .metadata.annotations["inference.opendatahub.io/routing-overlay-content-digest"]}}' >"$EVIDENCE/noop-before.json"
for resource in service/provider-provider-b serviceentry/provider-provider-b destinationrule/provider-provider-b httproute/external-model-demo-model; do
  kind=${resource%%/*}
  name=${resource#*/}
  "${KCTL[@]}" -n "$NS" get "$resource" -o json | jq '{kind, spec}' >"$EVIDENCE/noop-before-$kind-$name.json"
done
noop_token="noop-$STAMP"
"${KCTL[@]}" -n "$NS" patch externalprovider provider-b --type=merge -p="{\"spec\":{\"config\":{\"qualification-noop\":\"$noop_token\"}}}" >/dev/null
noop_reconciled=false
for _ in $(seq 1 30); do
  provider_generation=$("${KCTL[@]}" -n "$NS" get externalprovider provider-b -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
  provider_observed=$("${KCTL[@]}" -n "$NS" get externalprovider provider-b -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
  [[ "$provider_generation" == "$provider_observed" && "$provider_generation" != "" ]] && { noop_reconciled=true; break; }
  sleep 2
done
observe equal
"${KCTL[@]}" -n "$NS" get configmap routing-overlay -o json | jq '{data, annotations: {source: .metadata.annotations["inference.opendatahub.io/routing-overlay-source-generation"], digest: .metadata.annotations["inference.opendatahub.io/routing-overlay-content-digest"]}}' >"$EVIDENCE/noop-after.json"
resource_churn=false
for resource in service/provider-provider-b serviceentry/provider-provider-b destinationrule/provider-provider-b httproute/external-model-demo-model; do
  kind=${resource%%/*}
  name=${resource#*/}
  "${KCTL[@]}" -n "$NS" get "$resource" -o json | jq '{kind, spec}' >"$EVIDENCE/noop-after-$kind-$name.json"
  cmp -s "$EVIDENCE/noop-before-$kind-$name.json" "$EVIDENCE/noop-after-$kind-$name.json" || resource_churn=true
done
printf 'reconciled=%s resource_churn=%s overlay_equal=%s provider_generation=%s provider_observed=%s\n' "$noop_reconciled" "$resource_churn" "$(cmp -s "$EVIDENCE/noop-before.json" "$EVIDENCE/noop-after.json"; echo $?)" "$provider_generation" "$provider_observed" >"$EVIDENCE/noop-reconcile-state.txt"
if [[ "$noop_reconciled" == true && "$resource_churn" == false ]] && cmp -s "$EVIDENCE/noop-before.json" "$EVIDENCE/noop-after.json"; then record 13 semantic_noop_no_overlay_churn PASS; else record 13 semantic_noop_no_overlay_churn FAIL null "$(cat "$EVIDENCE/noop-reconcile-state.txt")"; fi
"${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' >"$EVIDENCE/readiness-before-overlay.json"
"${KCTL[@]}" -n "$NS" delete secret provider-credentials --wait=true >/dev/null
readiness_failed=false
for _ in $(seq 1 30); do
  model_phase=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.phase}' 2>/dev/null || true)
  model_reason=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)
  [[ "$model_phase" == Failed && "$model_reason" == ProviderNotReady ]] && { readiness_failed=true; break; }
  sleep 2
done
"${KCTL[@]}" -n "$NS" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' >"$EVIDENCE/readiness-failed-overlay.json"
readiness_uid=$before_uid
readiness_restarts=$before_restarts
readiness_lost=$(request readiness-lost "$MODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"readiness-loss"}]}' )
if [[ "$readiness_failed" == true && "$readiness_lost" == 200 ]] && cmp -s "$EVIDENCE/readiness-before-overlay.json" "$EVIDENCE/readiness-failed-overlay.json" && rg -q 'katan-b' "$EVIDENCE/request-readiness-lost.body"; then record 14 provider_status_gate_lkg_serving PASS "$readiness_lost" "mode=secret-delete"; else record 14 provider_status_gate_lkg_serving FAIL "$readiness_lost" "mode=secret-delete"; fi
"${KCTL[@]}" -n "$NS" create secret generic provider-credentials --from-literal=api-key=kind-only-dummy >/dev/null
recovered=false
for _ in $(seq 1 30); do
  model_phase=$("${KCTL[@]}" -n "$NS" get externalmodel demo-model -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$model_phase" == Ready ]] && { recovered=true; break; }
  sleep 2
done
readiness_recovered=$(request readiness-recovered "$MODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"readiness-recovery"}]}' )
recovery_uid=$("${KCTL[@]}" -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].metadata.uid}')
recovery_restarts=$("${KCTL[@]}" -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
if [[ "$recovered" == true && "$readiness_recovered" == 200 && "$readiness_uid" == "$recovery_uid" && "$readiness_restarts" == "$recovery_restarts" ]] && rg -q 'katan-b' "$EVIDENCE/request-readiness-recovered.body"; then record 15 provider_status_gate_recovery PASS "$readiness_recovered" "mode=secret-delete-restore"; else record 15 provider_status_gate_recovery FAIL "$readiness_recovered" "mode=secret-delete-restore"; fi

# Tenant-B qualification uses the separately provisioned Gateway, Praxis pod,
# overlay, provider Services, and MaaS tenant.  The backend namespace remains
# maas-system; tenant state is kept in ai-tenant-tenant-b.
BNS=${LOCAL_ENV_TENANT_B_NAMESPACE:-ai-tenant-tenant-b}
BMODEL_URL="http://127.0.0.1:$BPORT/$BNS/demo/v1/chat/completions"
b_phase=""
for _ in $(seq 1 30); do
  b_phase=$("${KCTL[@]}" -n "$BNS" get externalmodel demo-model -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$b_phase" == Ready ]] && break
  sleep 2
done
b_overlay=""
b_digest=""
if [[ "$b_phase" == Ready ]]; then
  b_overlay=$("${KCTL[@]}" -n "$BNS" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' 2>/dev/null || true)
  b_digest=$("${KCTL[@]}" -n "$BNS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
fi
if [[ "$b_phase" == Ready && -n "$b_overlay" && "$b_overlay" == *"provider-provider-a"* && "$b_overlay" != *"provider-provider-a-tenant-b"* ]]; then
  record 17 tenant_b_ready_and_scoped PASS null "tenant_namespace=$BNS backend_namespace=$API_NS digest=$b_digest"
else
  record 17 tenant_b_ready_and_scoped FAIL null "tenant_namespace=$BNS backend_namespace=$API_NS phase=$b_phase digest=$b_digest"
fi
if "${KCTL[@]}" -n "$BNS" get service/provider-provider-a serviceentry/provider-provider-a destinationrule/provider-provider-a httproute/external-model-demo-model >/dev/null 2>&1; then
  route_backend=$("${KCTL[@]}" -n "$BNS" get httproute external-model-demo-model -o jsonpath='{.spec.rules[0].backendRefs[0].name}' 2>/dev/null || true)
  record 18 tenant_b_transport_and_route PASS null "backend=$route_backend gateway=maas-tenant-b-gateway namespace=$BNS"
else
  record 18 tenant_b_transport_and_route FAIL null "namespace=$BNS"
fi
# Istio may initially observe the route before the tenant-local Praxis Service
# exists. The controller watches managed Services and reapplies the route; wait
# for the actual ResolvedRefs=True state before testing the boundary or sending
# tenant-B traffic.
for _ in $(seq 1 30); do
  boundary_b_route=$("${KCTL[@]}" -n "$BNS" get httproute external-model-demo-model -o json 2>/dev/null || echo '{}')
  boundary_b_resolved=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length' <<<"$boundary_b_route")
  [[ "$boundary_b_resolved" =~ ^[1-9][0-9]*$ ]] && break
  sleep 2
done
boundary_b_sa=$(auth_can_i get secrets --as="system:serviceaccount:$BNS:praxis-tenant-b" -n "$BNS")
boundary_b_cross=$(auth_can_i get secrets --as="system:serviceaccount:$BNS:praxis-tenant-b" -n "$NS")
printf '%s\n' "$boundary_b_route" >"$EVIDENCE/namespace-boundary-route-tenant-b.json"
printf 'tenant_namespace=%s gateway_namespace=%s backend_namespace=%s praxis_b_secret_api=%s praxis_b_cross_tenant_secret_api=%s\n' \
  "$BNS" "$GATEWAY_NS" \
  "$(jq -r '.spec.rules[0].backendRefs[0].namespace // .metadata.namespace // ""' <<<"$boundary_b_route")" \
  "$boundary_b_sa" "$boundary_b_cross" >"$EVIDENCE/namespace-boundary-tenant-b-state.txt"
b_parent_ns=$(jq -r '.spec.parentRefs[0].namespace // .metadata.namespace // ""' <<<"$boundary_b_route")
b_backend_name=$(jq -r '.spec.rules[0].backendRefs[0].name // ""' <<<"$boundary_b_route")
b_backend_ns=$(jq -r '.spec.rules[0].backendRefs[0].namespace // .metadata.namespace // ""' <<<"$boundary_b_route")
b_accepted=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length' <<<"$boundary_b_route")
b_resolved=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length' <<<"$boundary_b_route")
expected_b_backend=$(printf 'praxis-%s' "${BNS#ai-tenant-}")
if [[ "$b_parent_ns" == "$GATEWAY_NS" && "$b_backend_name" == "$expected_b_backend" && "$b_backend_ns" == "$BNS" && "$b_accepted" -gt 0 && "$b_resolved" -gt 0 && "$boundary_b_sa" == no && "$boundary_b_cross" == no ]]; then
  record 29 tenant_b_namespace_boundary_secret_isolation PASS null "tenant_namespace=$BNS gateway_namespace=$GATEWAY_NS backend_name=$b_backend_name backend_namespace=$BNS referencegrant_required=false praxis_secret_api=denied cross_tenant_secret_api=denied"
else
  record 29 tenant_b_namespace_boundary_secret_isolation FAIL null "$(cat "$EVIDENCE/namespace-boundary-tenant-b-state.txt") parent=$b_parent_ns backend_name=$b_backend_name expected_backend=$expected_b_backend accepted=$b_accepted resolved_refs=$b_resolved"
fi

# The fixture provider workloads are deliberately outside both tenant
# namespaces; the controller-created mesh transport remains tenant-local.
backend_a_ns=$("${KCTL[@]}" -n "$API_NS" get service provider-a -o jsonpath='{.metadata.namespace}' 2>/dev/null || true)
backend_b_ns=$("${KCTL[@]}" -n "$API_NS" get service provider-b -o jsonpath='{.metadata.namespace}' 2>/dev/null || true)
if [[ "$backend_a_ns" == "$API_NS" && "$backend_b_ns" == "$API_NS" ]]; then
  record 23 provider_backend_namespace_separation PASS null "backend_namespace=$API_NS tenant_a=$NS tenant_b=$BNS"
else
  record 23 provider_backend_namespace_separation FAIL null "backend_a_namespace=$backend_a_ns backend_b_namespace=$backend_b_ns expected=$API_NS"
fi

# ExtProc is a controller-owned Envoy processing workload; it is not a
# standalone Praxis credential consumer and has no provider Secret mount.
extproc_owner=$("${KCTL[@]}" -n "$API_NS" get deployment/payload-processing -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
extproc_secret_mounts=$("${KCTL[@]}" -n "$API_NS" get deployment/payload-processing -o json 2>/dev/null | jq '[.spec.template.spec.containers[].volumeMounts[]?.name | select(test("secret|credential";"i"))] | length' 2>/dev/null || echo 0)
if [[ "$extproc_owner" == ai-gateway-controller && "$extproc_secret_mounts" == 0 ]]; then
  record 27 controller_owned_extproc_without_provider_secret PASS null "managed_by=$extproc_owner provider_secret_mounts=0"
else
  record 27 controller_owned_extproc_without_provider_secret FAIL null "managed_by=$extproc_owner provider_secret_mounts=$extproc_secret_mounts"
fi
"${KCTL[@]}" -n "$API_NS" port-forward svc/maas-tenant-b-gateway "$BPORT:80" >"$EVIDENCE/tenant-b-port-forward.log" 2>&1 &
BPF=$!
for _ in $(seq 1 20); do
  rg -q 'Forwarding from' "$EVIDENCE/tenant-b-port-forward.log" && break
  sleep 1
done
b_known=$(request tenant-b-known "$BMODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"tenant-b"}]}' )
if [[ "$b_known" == 200 ]] && rg -q 'katan-a-tenant-b' "$EVIDENCE/request-tenant-b-known.body"; then
  record 19 tenant_b_positive_backend PASS "$b_known" "backend=tenant-b"
else
  record 19 tenant_b_positive_backend FAIL "$b_known" "$(cat "$EVIDENCE/request-tenant-b-known.body" 2>/dev/null || true)"
fi
# A tenant-B Gateway must not expose tenant-A's namespace/model path.  This is
# a received response assertion; request() performs no HTTP-status retries.
cross=$(request tenant-cross-boundary "$BMODEL_URL" -H 'content-type: application/json' --data '{"model":"not-the-tenant-model","messages":[]}' )
if [[ "$cross" == 404 ]]; then record 20 tenant_boundary_rejects_unknown_model PASS "$cross"; else record 20 tenant_boundary_rejects_unknown_model FAIL "$cross"; fi
b_before="$b_digest"
"${KCTL[@]}" -n "$NS" patch externalprovider provider-b --type=merge -p='{"spec":{"config":{"tenant-isolation-noop":"true"}}}' >/dev/null
a_reconciled=false
for _ in $(seq 1 30); do
  observed=$("${KCTL[@]}" -n "$NS" get externalprovider provider-b -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
  generation=$("${KCTL[@]}" -n "$NS" get externalprovider provider-b -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
  [[ -n "$generation" && "$generation" == "$observed" ]] && { a_reconciled=true; break; }
  sleep 2
done
b_after=$("${KCTL[@]}" -n "$BNS" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
if [[ "$a_reconciled" == true && "$b_before" == "$b_after" ]]; then record 21 tenant_a_mutation_does_not_change_tenant_b PASS; else record 21 tenant_a_mutation_does_not_change_tenant_b FAIL null "before=$b_before after=$b_after"; fi
# Do not delete the tenant-A ExternalModel here: this fixture is also the
# MaaS subscription's model reference, so deleting it intentionally retires
# the shared subscription and makes the next repeat run unauthenticated.
# Tenant-B survival after the A-side mutation must be a real authenticated
# request, not a fixture-only result. Controller cleanup itself is covered by
# focused reconciliation tests; this request proves the serving path remains.
b_survival=$(request tenant-b-after-a-mutation "$BMODEL_URL" -H 'content-type: application/json' --data '{"model":"demo","messages":[{"role":"user","content":"tenant-b-after-a-mutation"}]}' )
if [[ "$b_survival" == 200 ]] && rg -q 'katan-a-tenant-b' "$EVIDENCE/request-tenant-b-after-a-mutation.body"; then
  record 22 tenant_b_survives_tenant_a_mutation PASS "$b_survival" "cleanup_isolation=focused-controller-test; runtime_mutation_isolation=request_backend=tenant-b"
else
  record 22 tenant_b_survives_tenant_a_mutation FAIL "$b_survival" "cleanup_isolation=focused-controller-test; runtime_mutation_isolation=request_failed"
fi

# Deletion convergence is intentionally exercised after the routing assertions:
# a sibling keeps the namespace route set non-empty while the original model is
# deleted, then the final sibling deletion proves complete transport/overlay
# cleanup without waiting for an unrelated watch event.
deletion_ready=false
kubectl --context "kind-$CLUSTER" apply -f - >/dev/null <<EOF
apiVersion: inference.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: deletion-sibling
  namespace: $NS
spec:
  modelName: deletion-sibling
  externalProviderRefs:
  - ref:
      name: provider-b
    targetModel: gpt
    apiFormat: openai-chat
    path: /v1/chat/completions
EOF
for _ in $(seq 1 60); do
  sibling_phase=$("${KCTL[@]}" -n "$NS" get externalmodel deletion-sibling -o jsonpath='{.status.phase}' 2>/dev/null || true)
  sibling_route=$("${KCTL[@]}" -n "$NS" get httproute external-model-deletion-sibling >/dev/null 2>&1; echo $?)
  [[ "$sibling_phase" == Ready && "$sibling_route" == 0 ]] && { deletion_ready=true; break; }
  sleep 2
done
if [[ "$deletion_ready" == true ]]; then
  "${KCTL[@]}" -n "$NS" delete externalmodel demo-model --wait=false >/dev/null
  deletion_converged=false
  for _ in $(seq 1 60); do
    original_route=$("${KCTL[@]}" -n "$NS" get httproute external-model-demo-model >/dev/null 2>&1; echo $?)
    sibling_route=$("${KCTL[@]}" -n "$NS" get httproute external-model-deletion-sibling >/dev/null 2>&1; echo $?)
    provider_a_transport=$("${KCTL[@]}" -n "$NS" get service/provider-provider-a >/dev/null 2>&1; echo $?)
    [[ "$original_route" != 0 && "$sibling_route" == 0 && "$provider_a_transport" != 0 ]] && { deletion_converged=true; break; }
    sleep 2
  done
  "${KCTL[@]}" -n "$NS" delete externalmodel deletion-sibling --wait=false >/dev/null
  final_cleanup=false
  for _ in $(seq 1 60); do
    overlay_present=$("${KCTL[@]}" -n "$NS" get configmap routing-overlay >/dev/null 2>&1; echo $?)
    provider_b_transport=$("${KCTL[@]}" -n "$NS" get service/provider-provider-b >/dev/null 2>&1; echo $?)
    [[ "$overlay_present" != 0 && "$provider_b_transport" != 0 ]] && { final_cleanup=true; break; }
    sleep 2
  done
  if [[ "$deletion_converged" == true && "$final_cleanup" == true ]]; then
    record 37 externalmodel_deletion_convergence PASS null "sibling_route_preserved=true; stale_provider_transport_removed=true; final_overlay_and_transport_removed=true"
  else
    record 37 externalmodel_deletion_convergence FAIL null "sibling_ready=$deletion_ready; remaining_route=$([[ "$deletion_converged" == true ]] && echo false || echo true); final_cleanup=$final_cleanup"
  fi
else
  record 37 externalmodel_deletion_convergence FAIL null "first_boundary=sibling_externalmodel_not_ready"
fi
fi

finalize_results() {
  python3 - "$EVIDENCE/results.json" "$SUITE" <<'PY'
import json, os, sys, tempfile
p, suite = sys.argv[1:]
d = json.load(open(p))
d["suite"] = suite
d["assertion_count"] = len(d["assertions"])
d["functional_status"] = "PASS" if d["assertions"] and all(x["status"] in ("PASS", "NOT_DEMONSTRATED") for x in d["assertions"]) else "PARTIAL"
d["status"] = d["functional_status"]
fd, tmp = tempfile.mkstemp(prefix=".results.", dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2); f.flush(); os.fsync(f.fileno())
os.replace(tmp, p)
PY
  QUALIFICATION_COMPLETE=true
  cat "$EVIDENCE/results.json"
}

# Routing qualification never creates or mutates the transition fixture. The
# transition suite is intentionally separate so its follow-up failures cannot
# contaminate the routing result.
if [[ "$SUITE" == routing ]]; then
  finalize_results
  exit 0
fi

if [[ "$SUITE" == transition ]]; then
  CA_CERT=$(resolve_maas_api_ca) || { echo "transition suite could not verify the run-owned MaaS API CA" >&2; exit 2; }
  AUTH_HEADER_FILE=/dev/null
  request() { timeout 15s curl -sS -D "$EVIDENCE/request-$1.headers" -o "$EVIDENCE/request-$1.body" -w '%{http_code}' "$2" "${@:3}" -H "@${REQUEST_AUTH_HEADER_FILE:-$AUTH_HEADER_FILE}" || echo 000; }
fi

# Separate transition tenant: absent annotation means MaaS owns the existing IPP path.
TNS=ai-tenant-transition
TRANSITION_PRAXIS_NAME=praxis-transition
# The public path is derived from the ExternalModel resource name, as in the
# IPP and controller contracts: /<namespace>/<external-model-name>/*. The
# modelName sent in the body remains the MaaS-resolved "transition-model".
TRANSITION_IPP_URL="http://127.0.0.1:$TPORT/$TNS/transition-model/v1/chat/completions"
TRANSITION_PRAXIS_URL="http://127.0.0.1:$TPORT/$TNS/transition-model/v1/chat/completions"
transition_annotation=$(kubectl --context "kind-$CLUSTER" -n ai-tenants get aitenant transition -o jsonpath='{.metadata.annotations.maas\.opendatahub\.io/payload-processing-type}' 2>/dev/null || true)
ipp_before=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get deployment,service,configmap,envoyfilter -o json 2>/dev/null || echo '{}')
kubectl --context "kind-$CLUSTER" get httproute -A -o yaml >"$EVIDENCE/transition-routes-before.yaml" 2>&1 || true
kubectl --context "kind-$CLUSTER" -n "$TNS" get externalmodel,externalprovider -o yaml >"$EVIDENCE/transition-crs-before.yaml" 2>&1 || true
# The pre-transition ownership check is a prerequisite observation, not a
# separate assertion. Preserve it in evidence so the three transition
# assertions remain the reserved 24-26 range.
printf 'annotation=%s ipp_resources_present=%s overlay_present=%s\n' \
  "${transition_annotation:-absent}" \
  "$([[ "$ipp_before" == *"payload-processing-transition"* ]] && echo true || echo false)" \
  "$(kubectl --context "kind-$CLUSTER" -n "$TNS" get configmap routing-overlay >/dev/null 2>&1 && echo true || echo false)" \
  >"$EVIDENCE/transition-precondition.txt"
kubectl --context "kind-$CLUSTER" -n "$API_NS" port-forward svc/maas-transition-gateway "$TPORT:80" >"$EVIDENCE/transition-port-forward.log" 2>&1 &
TPF=$!
for _ in $(seq 1 20); do
  rg -q 'Forwarding from' "$EVIDENCE/transition-port-forward.log" && break
  sleep 1
done
# Transition has its own MaaS API/subscription. The main tenant key is
# intentionally not valid for this policy. The transition API key is minted
# only after the route and subscription readiness gates below converge.
TRANSITION_API_PORT=$((TPORT + 1))
kubectl --context "kind-$CLUSTER" -n "$API_NS" port-forward svc/maas-api-transition "$TRANSITION_API_PORT:8443" >"$EVIDENCE/maas-api-transition-port-forward.log" 2>&1 &
TAPF=$!
for _ in $(seq 1 20); do
  rg -q 'Forwarding from' "$EVIDENCE/maas-api-transition-port-forward.log" && break
  sleep 1
done
transition_route_ready=false
# Recreate the run-owned transition ExternalModel before observing the
# annotation-absent route. A retained same-cluster route may still reflect an
# earlier Gateway configuration; this sends a real ExternalModel event through
# the IPP controller without patching its generated HTTPRoute.
kubectl --context "kind-$CLUSTER" -n "$TNS" delete externalmodel transition-model --wait=true --ignore-not-found=true >/dev/null
kubectl --context "kind-$CLUSTER" apply -f "$ROOT/test/kind-env/manifests/42-transition-fixtures.yaml" >/dev/null
for _ in $(seq 1 60); do
  route_json=$("${KCTL[@]}" -n "$TNS" get httproute transition-model -o json 2>/dev/null || echo '{}')
  route_parent=$(jq -r '.spec.parentRefs[0] | ((.namespace // "") + "/" + (.name // ""))' <<<"$route_json")
  gateway_accepted=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length' <<<"$route_json")
  refs_resolved=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length' <<<"$route_json")
  gateway_endpoints=$("${KCTL[@]}" -n "$API_NS" get endpoints maas-transition-gateway -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
  if [[ "$route_parent" == "maas-system/maas-transition-gateway" && "$gateway_accepted" -gt 0 && "$refs_resolved" -gt 0 && -n "$gateway_endpoints" ]]; then
    transition_route_ready=true
    break
  fi
  sleep 2
done
if [[ "$transition_route_ready" != true ]]; then
  record 24 transition_ipp_request FAIL 000 "first_boundary=transition_route_not_ready"
  transition_ipp=000
else
  if ! wait_transition_writer_data_plane; then
    printf '%s\n' 'transition IPP writer Deployments or ready Endpoints were not stable before request' \
      >>"$EVIDENCE/transition-authorization-readiness.txt"
    transition_route_ready=false
  elif ! wait_transition_gateway_data_plane "ai-tenant-transition.transition-model" "provider-a-legacy"; then
    printf '%s\n' 'transition IPP route/backend was not present and healthy in Gateway Envoy before request' \
      >>"$EVIDENCE/transition-authorization-readiness.txt"
    transition_route_ready=false
  fi
  transition_subscription_ready=false
  for _ in $(seq 1 60); do
    transition_subscription_phase=$("${KCTL[@]}" -n "$TNS" get maassubscription transition-subscription -o jsonpath='{.status.phase}' 2>/dev/null || true)
    transition_subscription_condition=$("${KCTL[@]}" -n "$TNS" get maassubscription transition-subscription -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)
    transition_rate_limit_ready=$("${KCTL[@]}" -n "$TNS" get maassubscription transition-subscription -o json 2>/dev/null | jq -r '([.status.tokenRateLimitStatuses[]? | select(.name == "maas-trlp-transition-model" and .ready == true)] | length) > 0' || echo false)
    if [[ "$transition_subscription_phase" == Active && "$transition_subscription_condition" == True && "$transition_rate_limit_ready" == true ]]; then
      transition_subscription_ready=true
      break
    fi
    sleep 2
  done
  printf 'route_ready=%s subscription_ready=%s rate_limit_ready=%s phase=%s condition=%s\n' \
    "$transition_route_ready" "$transition_subscription_ready" \
    "${transition_rate_limit_ready:-unknown}" "${transition_subscription_phase:-unknown}" "${transition_subscription_condition:-unknown}" \
    >"$EVIDENCE/transition-authorization-readiness.txt"
  if [[ "$transition_route_ready" != true || "$transition_subscription_ready" != true ]]; then
    transition_ipp=000
  printf '%s\n' 'transition data plane or subscription did not become Ready before the transition request' \
      >>"$EVIDENCE/transition-authorization-readiness.txt"
  else
    # Keep the response and token out of evidence. A missing key is a
    # qualification failure at the API boundary, not a shell-abort condition.
    transition_key_response=$(timeout 15s curl --noproxy '*' --cacert "$CA_CERT" --resolve "maas-api-transition.maas-system.svc.cluster.local:$TRANSITION_API_PORT:127.0.0.1" -sS -H 'content-type: application/json' -H 'X-MaaS-Username: kind-user' -H 'X-MaaS-Group: ["system:authenticated"]' --data '{"name":"kind-transition-e2e","ephemeral":true,"subscription":"transition-subscription"}' "https://maas-api-transition.maas-system.svc.cluster.local:$TRANSITION_API_PORT/v1/api-keys" || true)
    transition_key=$(jq -er '.key' <<<"$transition_key_response" 2>/dev/null || true)
    unset transition_key_response
    if [[ -n "$transition_key" ]]; then
      TRANSITION_AUTH_HEADER_FILE="$EVIDENCE/.transition-auth-header"
      printf 'Authorization: Bearer %s\n' "$transition_key" >"$TRANSITION_AUTH_HEADER_FILE"
      unset transition_key
      transition_key_ready=true
    else
      transition_key_ready=false
      printf '%s\n' 'transition API did not return an ephemeral key' \
        >>"$EVIDENCE/transition-authorization-readiness.txt"
    fi
    if [[ "$transition_key_ready" == true ]]; then
REQUEST_AUTH_HEADER_FILE="$TRANSITION_AUTH_HEADER_FILE"
transition_ipp=$(request transition-ipp "$TRANSITION_IPP_URL" -H 'content-type: application/json' --data '{"model":"transition-model","messages":[{"role":"user","content":"existing-ipp"}]}' )
    else
      transition_ipp=000
    fi
  fi
fi
if [[ "$transition_ipp" == 200 ]] && rg -q 'katan-transition' "$EVIDENCE/request-transition-ipp.body"; then
  record 24 transition_ipp_request PASS "$transition_ipp" "path=ipp backend=transition"
elif [[ "$transition_route_ready" == true ]]; then
  record 24 transition_ipp_request FAIL "$transition_ipp" "path=ipp"
fi

"${KCTL[@]}" -n ai-tenants annotate aitenant transition maas.opendatahub.io/payload-processing-type=praxis --overwrite >/dev/null
kubectl --context "kind-$CLUSTER" get httproute -A -o yaml >"$EVIDENCE/transition-routes-after-annotation.yaml" 2>&1 || true
# The controller intentionally leaves the production Praxis pod identity
# unpinned for OpenShift restricted SCC. Kind cannot verify the image's named
# non-root user, so apply the same run-owned numeric identity patch used for
# the base Kind workloads before evaluating transition readiness.
for _ in $(seq 1 60); do
  if "${KCTL[@]}" -n "$TNS" get deployment/"$TRANSITION_PRAXIS_NAME" >/dev/null 2>&1; then
    "${KCTL[@]}" -n "$TNS" patch deployment "$TRANSITION_PRAXIS_NAME" --type=merge \
      -p='{"spec":{"template":{"spec":{"securityContext":{"runAsUser":65532,"runAsGroup":65532,"fsGroup":65532}}}}}' >/dev/null
    break
  fi
  sleep 2
done
cutover_ready=false
for _ in $(seq 1 60); do
  overlay_exists=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get configmap routing-overlay >/dev/null 2>&1; echo $?)
  route_json=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get httproute/external-model-transition-model -o json 2>/dev/null || echo '{}')
  route_exists=$([[ "$route_json" != '{}' ]] && echo 0 || echo 1)
  praxis_route_accepted=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length' <<<"$route_json")
  praxis_route_resolved=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length' <<<"$route_json")
  praxis_deployment_ready=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get deployment/"$TRANSITION_PRAXIS_NAME" -o json 2>/dev/null | jq -r '(.spec.replicas // 0) > 0 and (.status.readyReplicas // 0) == (.spec.replicas // 0) and (.status.updatedReplicas // 0) == (.spec.replicas // 0)' || echo false)
  praxis_service_exists=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get service/"$TRANSITION_PRAXIS_NAME" >/dev/null 2>&1; echo $?)
  transition_rate_limit_ready=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get maassubscription transition-subscription -o json 2>/dev/null | jq -r '([.status.tokenRateLimitStatuses[]? | select(.name == "maas-trlp-transition-model" and .ready == true)] | length) > 0' || echo false)
  ipp_writer_exists=false
  for ipp_deployment in payload-processing-transition payload-pre-processing-transition; do
    ipp_managed_by=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get deployment "$ipp_deployment" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
    if [[ -n "$ipp_managed_by" && "$ipp_managed_by" != "ai-gateway-controller" ]]; then
      ipp_writer_exists=true
      break
    fi
  done
  ipp_route_exists=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get httproute/transition-model >/dev/null 2>&1; echo $?)
  [[ "$overlay_exists" == 0 && "$route_exists" == 0 && "$praxis_route_accepted" -gt 0 && "$praxis_route_resolved" -gt 0 && "$praxis_deployment_ready" == true && "$praxis_service_exists" == 0 && "$transition_rate_limit_ready" == true && "$ipp_writer_exists" == false && "$ipp_route_exists" != 0 ]] && { cutover_ready=true; break; }
  sleep 2
done
ipp_rbac_removed=false
if [[ "$cutover_ready" == true && "$ipp_writer_exists" == false ]]; then
  # The transition-only IPP RBAC is separate from the controller's reader
  # binding. Remove it only after the IPP writer has disappeared, so the
  # annotation switch cannot leave a disabled writer with extra permissions.
  "${KCTL[@]}" -n ai-tenant-transition delete rolebinding/payload-processing-ipp-reader-transition --ignore-not-found=true --wait=true >/dev/null
  "${KCTL[@]}" -n ai-tenant-transition delete role/payload-processing-ipp-reader-transition --ignore-not-found=true --wait=true >/dev/null
  if ! "${KCTL[@]}" -n ai-tenant-transition get rolebinding/payload-processing-ipp-reader-transition >/dev/null 2>&1 && \
    ! "${KCTL[@]}" -n ai-tenant-transition get role/payload-processing-ipp-reader-transition >/dev/null 2>&1; then
    ipp_rbac_removed=true
  fi
fi
printf 'overlay=%s route=%s accepted=%s resolved_refs=%s service=%s deployment_ready=%s rate_limit_ready=%s ipp_writer=%s %s ipp_route=%s\n' \
  "$([[ "$overlay_exists" == 0 ]] && echo true || echo false)" \
  "$([[ "$route_exists" == 0 ]] && echo true || echo false)" \
  "$praxis_route_accepted" "$praxis_route_resolved" \
  "$([[ "$praxis_service_exists" == 0 ]] && echo true || echo false)" \
  "$praxis_deployment_ready" "$transition_rate_limit_ready" \
  "$ipp_writer_exists" "ipp_rbac_removed=$ipp_rbac_removed" \
  "$([[ "$ipp_route_exists" == 0 ]] && echo true || echo false)" \
  >"$EVIDENCE/transition-cutover-readiness.txt"
ipp_after_cutover_count=0
for ipp_deployment in payload-processing-transition payload-pre-processing-transition; do
  ipp_managed_by=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get deployment "$ipp_deployment" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)
  if [[ -n "$ipp_managed_by" && "$ipp_managed_by" != "ai-gateway-controller" ]]; then
    ipp_after_cutover_count=$((ipp_after_cutover_count + 1))
  fi
done
stale_ipp_route_after_cutover=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get httproute transition-model -o json 2>/dev/null || echo '{}')
stale_ipp_route_owner=$(jq -r '.metadata.labels["app.kubernetes.io/managed-by"] // "absent"' <<<"$stale_ipp_route_after_cutover")
if [[ "$cutover_ready" == true && "$ipp_after_cutover_count" == 0 && "$ipp_rbac_removed" == true && "$stale_ipp_route_owner" == "absent" ]]; then
  record 25 transition_cutover_ownership PASS null "existing_ipp_resources_removed=true praxis_resources=tenant-scoped"
else
  record 25 transition_cutover_ownership FAIL null "cutover_ready=$cutover_ready existing_ipp_resources_present=$([[ "$ipp_after_cutover_count" != 0 ]] && echo true || echo false) ipp_rbac_removed=$ipp_rbac_removed stale_ipp_route_owner=$stale_ipp_route_owner"
fi
if [[ "$cutover_ready" == true ]]; then
  if ! wait_transition_praxis_data_plane || ! wait_transition_gateway_data_plane "external-model-transition-model" "praxis-transition"; then
    printf '%s\n' 'transition Praxis workload or Gateway route/backend was not stable before request' \
      >>"$EVIDENCE/transition-cutover-readiness.txt"
    cutover_ready=false
  fi
fi
transition_praxis=000
if [[ "$cutover_ready" == true ]]; then
  transition_praxis=$(request transition-praxis "$TRANSITION_PRAXIS_URL" -H 'content-type: application/json' --data '{"model":"transition-model","messages":[{"role":"user","content":"praxis"}]}' )
fi
kubectl --context "kind-$CLUSTER" get httproute -A -o yaml >"$EVIDENCE/transition-routes-after-cutover.yaml" 2>&1 || true
transition_gateway_pod=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get pods -l gateway.networking.k8s.io/gateway-name=maas-transition-gateway -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$transition_gateway_pod" ]]; then kubectl --context "kind-$CLUSTER" -n "$API_NS" logs "$transition_gateway_pod" --all-containers --tail=200 >"$EVIDENCE/transition-gateway-logs.txt" 2>&1 || true; else : >"$EVIDENCE/transition-gateway-logs.txt"; fi
kubectl --context "kind-$CLUSTER" -n "$API_NS" logs deployment/payload-processing-transition --all-containers --tail=200 >"$EVIDENCE/transition-ipp-processing-logs.txt" 2>&1 || true
kubectl --context "kind-$CLUSTER" -n "$API_NS" logs deployment/payload-pre-processing-transition --all-containers --tail=200 >"$EVIDENCE/transition-ipp-preprocessing-logs.txt" 2>&1 || true
kubectl --context "kind-$CLUSTER" -n "$TNS" logs deployment/"$TRANSITION_PRAXIS_NAME" --all-containers --tail=200 >"$EVIDENCE/transition-praxis-logs.txt" 2>&1 || true
kubectl --context "kind-$CLUSTER" -n ai-tenants annotate aitenant transition maas.opendatahub.io/payload-processing-type- >/dev/null
rollback_ready=false
for _ in $(seq 1 60); do
  annotation_after=$(kubectl --context "kind-$CLUSTER" -n ai-tenants get aitenant transition -o jsonpath='{.metadata.annotations.maas\.opendatahub\.io/payload-processing-type}' 2>/dev/null || true)
  ipp_restored=$(kubectl --context "kind-$CLUSTER" -n "$API_NS" get deployment -o name 2>/dev/null | rg -q 'payload-processing-transition' && echo true || echo false)
  overlay_gone=$(kubectl --context "kind-$CLUSTER" -n "$TNS" get configmap routing-overlay >/dev/null 2>&1; echo $?)
  [[ -z "$annotation_after" && "$ipp_restored" == true && "$overlay_gone" != 0 ]] && { rollback_ready=true; break; }
  sleep 2
done
transition_rollback=000
if [[ "$rollback_ready" == true ]]; then
  # MaaS recreates the existing IPP writer after Praxis opt-out. Reapply the
  # transition-scoped IPP cache and Gateway settings before evaluating the
  # restored route; otherwise the process can recreate it against the default
  # Gateway and a rollback request would test the wrong topology.
  for ipp_deployment in payload-processing-transition payload-pre-processing-transition; do
    "${KCTL[@]}" -n "$API_NS" set env deployment/"$ipp_deployment" \
      NAMESPACE=ai-tenant-transition TENANT_NAMESPACE=ai-tenant-transition \
      GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-transition-gateway \
      DISABLE_EXTERNAL_MODEL_CONTROLLER=false >/dev/null
    "${KCTL[@]}" -n "$API_NS" rollout status deployment/"$ipp_deployment" --timeout=120s >/dev/null
  done
  # Recreate the run-owned transition ExternalModel after the restored IPP
  # writers are ready. Reapplying an unchanged object does not deliver an
  # ExternalModel event, so an old IPP route can remain attached to the
  # previous/default Gateway after a controller restart. Deleting and
  # recreating the fixture lets the IPP controller rebuild its route from the
  # configured Gateway; the generated HTTPRoute itself is never patched by the
  # harness.
  kubectl --context "kind-$CLUSTER" -n "$TNS" delete externalmodel transition-model --wait=true --ignore-not-found=true >/dev/null
  kubectl --context "kind-$CLUSTER" apply -f "$ROOT/test/kind-env/manifests/42-transition-fixtures.yaml" >/dev/null
  for ipp_deployment in payload-processing-transition payload-pre-processing-transition; do
    "${KCTL[@]}" -n "$API_NS" set env deployment/"$ipp_deployment" \
      NAMESPACE=ai-tenant-transition TENANT_NAMESPACE=ai-tenant-transition \
      GATEWAY_NAMESPACE=maas-system GATEWAY_NAME=maas-transition-gateway \
      DISABLE_EXTERNAL_MODEL_CONTROLLER=false >/dev/null
    "${KCTL[@]}" -n "$API_NS" rollout status deployment/"$ipp_deployment" --timeout=120s >/dev/null
  done
  rollback_route_ready=false
  for _ in $(seq 1 60); do
    rollback_route_json=$("${KCTL[@]}" -n "$TNS" get httproute transition-model -o json 2>/dev/null || echo '{}')
    rollback_parent=$(jq -r '.spec.parentRefs[0] | ((.namespace // "") + "/" + (.name // ""))' <<<"$rollback_route_json")
    rollback_accepted=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length' <<<"$rollback_route_json")
    rollback_refs=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length' <<<"$rollback_route_json")
    if [[ "$rollback_parent" == "maas-system/maas-transition-gateway" && "$rollback_accepted" -gt 0 && "$rollback_refs" -gt 0 ]]; then
      rollback_route_ready=true
      break
    fi
    sleep 2
  done
  if [[ "$rollback_route_ready" == true ]]; then
    if wait_transition_writer_data_plane && wait_transition_gateway_data_plane "ai-tenant-transition.transition-model" "provider-a-legacy"; then
      transition_rollback=$(request transition-rollback "$TRANSITION_IPP_URL" -H 'content-type: application/json' --data '{"model":"transition-model","messages":[{"role":"user","content":"rollback"}]}' )
    else
      printf '%s\n' 'restored IPP writer or Gateway route/backend was not stable before rollback request' \
        >>"$EVIDENCE/transition-rollback-route.txt"
    fi
  fi
  printf 'rollback_route_ready=%s parent=%s accepted=%s resolved_refs=%s\n' \
    "$rollback_route_ready" "${rollback_parent:-unknown}" "${rollback_accepted:-unknown}" "${rollback_refs:-unknown}" \
    >"$EVIDENCE/transition-rollback-route.txt"
  if [[ "$transition_praxis" == 200 ]] && rg -q 'via: 1.1 praxis' "$EVIDENCE/request-transition-praxis.headers"; then
    if [[ "$rollback_route_ready" == true && "$transition_rollback" == 200 ]]; then
      record 26 transition_praxis_and_rollback PASS "$transition_praxis" "path=praxis rollback_http=$transition_rollback praxis_cleanup=true ipp_restored=true"
    else
      record 26 transition_praxis_and_rollback FAIL "$transition_praxis" "path=praxis rollback_http=$transition_rollback rollback_route_ready=$rollback_route_ready"
    fi
  else
    record 26 transition_praxis_and_rollback FAIL "$transition_praxis" "path=praxis rollback_http=$transition_rollback"
  fi
else
  record 26 transition_praxis_and_rollback FAIL "$transition_praxis" "path=praxis rollback_http=$transition_rollback praxis_cleanup_or_ipp_restore_failed=true"
fi
"${KCTL[@]}" get events -A --sort-by=.lastTimestamp >"$EVIDENCE/events.txt" 2>&1 || true
python3 - "$EVIDENCE/results.json" <<'PY'
import json, os, sys, tempfile
p=sys.argv[1]; d=json.load(open(p)); d["status"]="PASS" if d["assertions"] and all(x["status"] in ("PASS", "NOT_DEMONSTRATED") for x in d["assertions"]) else "PARTIAL"; d["suite"]="all" if "all" == os.environ.get("E2E_SUITE") else os.environ.get("E2E_SUITE", "all"); d["assertion_count"]=len(d["assertions"]); d["functional_status"]=d["status"]
fd, tmp = tempfile.mkstemp(prefix=".results.", dir=os.path.dirname(p))
with os.fdopen(fd, "w") as f:
    json.dump(d, f, indent=2)
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp, p)
PY
QUALIFICATION_COMPLETE=true
cat "$EVIDENCE/results.json"
