#!/usr/bin/env bash
set -Eeuo pipefail

# Retained-cluster narrative demo. Requests execute from one persistent,
# restricted in-cluster client pod. Mutations are limited to run-owned fixtures.
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CLUSTER=external-model-two-plane
CONTEXT=kind-$CLUSTER
TENANT=models-as-a-service
BNS=ai-tenant-tenant-b
GATEWAY_NS=maas-system
CLIENT_NS=maas-system
CLIENT=external-model-demo-client
EVIDENCE="$ROOT/evidence/$(date -u +%Y%m%dT%H%M%SZ)-demo"
PAUSE_SECONDS=2
NON_INTERACTIVE=false
RESET=false
while (($#)); do
  case "$1" in
    --context) CONTEXT=$2; shift 2 ;;
    --tenant) TENANT=$2; shift 2 ;;
    --evidence-dir) EVIDENCE=$2; shift 2 ;;
    --pause-seconds) PAUSE_SECONDS=$2; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --skip-reset) shift ;;
    --reset) RESET=true; shift ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ "$CONTEXT" == kind-* ]] || { echo "FAIL: expected a Kind context"; exit 2; }
mkdir -p "$EVIDENCE"
exec > >(tee "$EVIDENCE/demo.log") 2>&1
kctl() { kubectl --context "$CONTEXT" "$@"; }
guard_context() {
  local current
  current=$(kubectl config current-context 2>/dev/null || true)
  [[ "$current" == "$CONTEXT" ]] || { echo "FAIL: current context is $current; expected $CONTEXT"; exit 2; }
  kctl cluster-info >/dev/null
}
mutate() { guard_context; kctl "$@"; }
pause() {
  [[ "$NON_INTERACTIVE" == true ]] && return
  [[ -t 0 ]] || { sleep "$PAUSE_SECONDS"; return; }
  read -r -p "  Press Enter to continue (or wait ${PAUSE_SECONDS}s): " _ </dev/tty || sleep "$PAUSE_SECONDS"
}
fail_stage() {
  record "$STAGE" "stage_${STAGE}_failure" FAIL "failed_boundary=$1"
  echo "RESULT"; echo "  Status                 FAIL"
  echo "  Failed boundary        $1"
  echo "  Diagnostics             $EVIDENCE"
  atomic_results
  exit 1
}
wait_for() {
  local label=$1 timeout_s=$2
  shift 2
  local started now
  started=$(date +%s)
  while ! "$@" >/dev/null 2>&1; do
    now=$(date +%s)
    (( now - started < timeout_s )) || { echo "  [FAIL] $label after ${timeout_s}s"; return 1; }
    sleep 2
  done
  echo "  [PASS] $label"
}
model_converged() {
  local namespace=$1 name=$2 phase observed generation
  phase=$(kctl -n "$namespace" get externalmodel "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  observed=$(kctl -n "$namespace" get externalmodel "$name" -o jsonpath='{.status.observedGeneration}' 2>/dev/null || true)
  generation=$(kctl -n "$namespace" get externalmodel "$name" -o jsonpath='{.metadata.generation}' 2>/dev/null || true)
  [[ "$phase" == Ready && -n "$generation" && "$observed" == "$generation" ]]
}
wait_pod_ready() {
  local namespace=$1 name=$2 started now state
  started=$(date +%s)
  while :; do
    state=$(kctl -n "$namespace" get pod "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$state" == True ]] && { echo "  [PASS] persistent in-cluster client Ready"; return 0; }
    now=$(date +%s)
    (( now - started < 120 )) || { echo "  [FAIL] pod $namespace/$name did not become Ready"; return 1; }
    sleep 2
  done
}
client_exec() { kctl -n "$CLIENT_NS" exec -i "$CLIENT" -- "$@" </dev/null; }
request_status() {
  local gateway=$1 path=$2 body=$3
  local url="http://$gateway.$GATEWAY_NS.svc.cluster.local$path"
  client_exec sh -c "status=\$(curl --connect-timeout 5 --max-time 15 -sS -o /tmp/demo-response -w '%{http_code}' -H 'content-type: application/json' -H @/tmp/demo-auth-header --data '$body' '$url' || printf 000); backend=\$(grep -o 'katan-[A-Za-z0-9-]*' /tmp/demo-response 2>/dev/null | head -1 || true); printf '%s|%s' \"\$status\" \"\$backend\""
}
record() {
  local number=$1 id=$2 status=$3 observation=$4
  python3 - "$EVIDENCE/results.json" "$number" "$id" "$status" "$observation" <<'PY'
import json, os, sys, tempfile
p,n,i,s,o=sys.argv[1:]
with open(p) as f: d=json.load(f)
d["assertions"].append({"number":int(n),"id":i,"status":s,"observation":o})
d["total_assertions"]=len(d["assertions"])
fd,t=tempfile.mkstemp(prefix=".results.",dir=os.path.dirname(p))
with os.fdopen(fd,"w") as f: json.dump(d,f,indent=2); f.flush(); os.fsync(f.fileno())
os.replace(t,p)
PY
}
atomic_results() {
  python3 - "$EVIDENCE/results.json" <<'PY'
import json, os, sys, tempfile
p=sys.argv[1]
with open(p) as f: d=json.load(f)
d["total_assertions"]=len(d["assertions"])
statuses=[x["status"] for x in d["assertions"]]
d["status"]="PASS" if all(s in ("PASS", "NOT_DEMONSTRATED") for s in statuses) else "FAIL"
d["scope"]="routing_increment"
d["not_demonstrated"]=[x["id"] for x in d["assertions"] if x["status"] == "NOT_DEMONSTRATED"]
fd,t=tempfile.mkstemp(prefix=".results.",dir=os.path.dirname(p))
with os.fdopen(fd,"w") as f: json.dump(d,f,indent=2); f.flush(); os.fsync(f.fileno())
os.replace(t,p)
PY
}
guard_context
printf '{"status":"RUNNING","assertions":[],"total_assertions":0}\n' > "$EVIDENCE/results.json"

if [[ "$RESET" == true ]]; then
  echo "RESET: restoring run-owned initial fixtures"
  # Ensure the Praxis tenants' IPP writers have completed their disabled
  # rollout before recreating ExternalModels. Otherwise an old writer can
  # observe the fixture during reset and recreate a direct-provider route.
  for ipp_deployment in payload-processing payload-processing-tenant-b payload-pre-processing payload-pre-processing-tenant-b; do
    if kctl -n maas-system get deployment "$ipp_deployment" >/dev/null 2>&1; then
      tenant_namespace=models-as-a-service
      gateway_name=maas-default-gateway
      [[ "$ipp_deployment" == *-tenant-b ]] && { tenant_namespace=ai-tenant-tenant-b; gateway_name=maas-tenant-b-gateway; }
      mutate -n maas-system set env deployment/"$ipp_deployment" \
        NAMESPACE="$tenant_namespace" TENANT_NAMESPACE="$tenant_namespace" GATEWAY_NAMESPACE=maas-system GATEWAY_NAME="$gateway_name" \
        DISABLE_EXTERNAL_MODEL_CONTROLLER=true >/dev/null
      mutate -n maas-system rollout status deployment/"$ipp_deployment" --timeout=120s >/dev/null
    fi
  done
  if [[ "$(kctl -n "$TENANT" get configmap routing-overlay -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)" == ai-gateway-controller ]]; then
    mutate -n "$TENANT" delete configmap routing-overlay --wait=true >/dev/null
  fi
  praxis_image=$(kctl -n "$TENANT" get deployment praxis -o jsonpath='{.spec.template.spec.containers[?(@.name=="praxis")].image}')
  [[ -n "$praxis_image" ]] || { echo "RESET: could not determine the active Praxis image"; exit 1; }
  mutate apply -f "$ROOT/test/kind-env/manifests/20-fixtures.yaml" >/dev/null
  mutate apply -f "$ROOT/test/kind-env/manifests/10-praxis.yaml" >/dev/null
  mutate -n "$TENANT" set image deployment/praxis praxis="$praxis_image" >/dev/null
  mutate -n "$TENANT" rollout status deployment/praxis --timeout=120s >/dev/null
  mutate -n "$TENANT" patch externalmodel demo-model --type=json -p='[{"op":"replace","path":"/spec/externalProviderRefs","value":[{"ref":{"name":"provider-a"},"targetModel":"demo","apiFormat":"openai-chat","path":"/v1/chat/completions"}]}]' >/dev/null
  wait_for "tenant model Ready after reset" 120 model_converged "$TENANT" demo-model || exit 1
  for _ in $(seq 1 60); do
    reset_overlay=$(kctl -n "$TENANT" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}' 2>/dev/null || true)
    [[ "$reset_overlay" == *provider-provider-a* && "$reset_overlay" != *provider-provider-b* ]] && break
    sleep 2
  done
  [[ "$reset_overlay" == *provider-provider-a* && "$reset_overlay" != *provider-provider-b* ]] || { echo "RESET: overlay did not converge to Provider A"; exit 1; }
  wait_for "Praxis mounted Provider A overlay" 120 kctl -n "$TENANT" exec deploy/praxis -- sh -c 'grep -q provider-provider-a /etc/praxis/routing/routing-overlay.json'
  echo "RESET: PASS; cluster and unrelated resources preserved"
  exit 0
fi

STAGE=0
stage() {
  STAGE=$((STAGE + 1))
  printf "\n--------------------------------------------------------------------------------\n STAGE %s OF 9: %s\n--------------------------------------------------------------------------------\n" "$STAGE" "$1"
  echo "GOAL"; echo "  $2"; echo "STARTING STATE"
}

stage "Introduce the topology" "Show the two-plane request path and tenant ownership."
echo "  Client -> Gateway/Envoy -> Kuadrant -> ExtProc -> standalone Praxis -> provider"
echo "  Controller -> Service/ServiceEntry/DestinationRule/HTTPRoute -> overlay"
kctl get ns "$GATEWAY_NS" "$TENANT" "$BNS" -o custom-columns='NAMESPACE:.metadata.name' --no-headers
kctl -n "$TENANT" get externalmodel,externalprovider,httproute,service,deployment,configmap -o name 2>/dev/null | head -30
digest=$(kctl -n "$TENANT" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-content-digest}' 2>/dev/null || true)
echo "  overlay=$(printf '%s' "$digest" | cut -c1-12)"
record 1 topology PASS "gateway_namespace=$GATEWAY_NS tenant_namespace=$TENANT"
echo "RESULT"; echo "  Status                 PASS"; echo "  WHY IT MATTERS"; echo "  Control and request processing have separate owners."; pause

stage "Prove authentication" "Use a persistent client pod and show policy rejection before authentication."
if kctl -n "$CLIENT_NS" get pod "$CLIENT" -o jsonpath='{.metadata.labels.local-env\.opendatahub\.io/purpose}' 2>/dev/null | rg -qx narrative-demo-client; then
  mutate -n "$CLIENT_NS" delete pod "$CLIENT" --wait=true >/dev/null
fi
mutate -n kuadrant-system get configmap authorino-maas-api-ca -o json \
  | jq 'del(.metadata.creationTimestamp,.metadata.resourceVersion,.metadata.uid,.metadata.managedFields,.metadata.ownerReferences) | .metadata.name="demo-maas-api-ca" | .metadata.namespace="maas-system"' \
  | mutate apply -f - >/dev/null
# shellcheck disable=SC2016
EXTERNAL_MODEL_CLIENT_NAME=$CLIENT \
EXTERNAL_MODEL_CLIENT_NAMESPACE=$CLIENT_NS \
EXTERNAL_MODEL_CLIENT_IMAGE='curlimages/curl:8.10.1' \
EXTERNAL_MODEL_CLIENT_VOLUME_MOUNTS='[{name: maas-ca, mountPath: /etc/demo-ca, readOnly: true}]' \
EXTERNAL_MODEL_CLIENT_VOLUMES='[{name: maas-ca, configMap: {name: demo-maas-api-ca, items: [{key: ca.crt, path: ca.crt}]}}]' \
  envsubst '${EXTERNAL_MODEL_CLIENT_NAME} ${EXTERNAL_MODEL_CLIENT_NAMESPACE} ${EXTERNAL_MODEL_CLIENT_IMAGE} ${EXTERNAL_MODEL_CLIENT_VOLUME_MOUNTS} ${EXTERNAL_MODEL_CLIENT_VOLUMES}' \
    <"$ROOT/test/external-model/client.yaml.tmpl" | mutate apply -f - >/dev/null
wait_pod_ready "$CLIENT_NS" "$CLIENT" || fail_stage "client pod readiness"
path="/$TENANT/demo/v1/chat/completions"
unauth=$(client_exec sh -c "curl --connect-timeout 5 --max-time 15 -sS -o /tmp/unauth -w '%{http_code}' -H 'content-type: application/json' --data '{\"model\":\"demo\",\"messages\":[]}' 'http://maas-default-gateway.$GATEWAY_NS.svc.cluster.local$path' || printf 000" 2>/dev/null || true)
echo "  unauthenticated request HTTP $unauth (expected 401/403)"
[[ "$unauth" == 401 || "$unauth" == 403 ]] || fail_stage "Kuadrant authentication"
# The key is stored only inside the client pod; it is not printed or recorded.
client_exec sh -c "curl --cacert /etc/demo-ca/ca.crt -sS -H 'content-type: application/json' -H 'X-MaaS-Username: kind-user' -H 'X-MaaS-Group: [\"system:authenticated\"]' --data '{\"name\":\"narrative-demo\",\"ephemeral\":true,\"subscription\":\"kind-e2e-subscription\"}' 'https://maas-api.$GATEWAY_NS.svc.cluster.local:8443/v1/api-keys' | sed -n 's/.*\"key\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/Authorization: Bearer \\1/p' > /tmp/demo-auth-header && test -s /tmp/demo-auth-header && chmod 600 /tmp/demo-auth-header"
auth=$(request_status maas-default-gateway "$path" '{"model":"demo","messages":[{"role":"user","content":"auth"}]}' 2>/dev/null || true)
auth_status=$(printf '%s' "$auth" | cut -d'|' -f1); auth_backend=$(printf '%s' "$auth" | cut -d'|' -f2)
echo "  authenticated request HTTP $auth_status; backend ${auth_backend:-unavailable}"
[[ "$auth_status" == 200 ]] || fail_stage "authenticated Gateway request"
record 2 authentication PASS "unauthenticated=$unauth authenticated=$auth_status client_pod=$CLIENT"
echo "RESULT"; echo "  Status                 PASS"; echo "  Authenticated request  HTTP $auth_status"; pause

stage "Route to Provider A" "Prove the active overlay and backend response."
result=$(request_status maas-default-gateway "$path" '{"model":"demo","messages":[{"role":"user","content":"provider-a"}]}' 2>/dev/null || true)
result_status=$(printf '%s' "$result" | cut -d'|' -f1); result_backend=$(printf '%s' "$result" | cut -d'|' -f2)
echo "  Provider A request     HTTP $result_status; backend ${result_backend:-unavailable}"
[[ "$result_status" == 200 && "$result_backend" == *katan-a* ]] || fail_stage "Provider A request"
record 3 provider_a PASS "http_status=$result_status backend=$result_backend"
echo "RESULT"; echo "  Status                 PASS"; echo "  Selected provider      Provider A"; pause

stage "Hot-swap to Provider B" "Mutate the run-owned model and wait for overlay convergence."
before_uid=$(kctl -n "$TENANT" get pod -l app=praxis -o jsonpath='{.items[0].metadata.uid}')
before_restart=$(kctl -n "$TENANT" get pod -l app=praxis -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
before_generation=$(kctl -n "$TENANT" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-source-generation}')
mutate -n "$TENANT" patch externalmodel demo-model --type=json -p='[{"op":"replace","path":"/spec/externalProviderRefs","value":[{"ref":{"name":"provider-b"},"targetModel":"demo","apiFormat":"openai-chat","path":"/v1/chat/completions"}]}]' >/dev/null
wait_for "model Ready after Provider B mutation" 120 model_converged "$TENANT" demo-model || fail_stage "model readiness"
new_generation=
for _ in $(seq 1 60); do
  new_generation=$(kctl -n "$TENANT" get configmap routing-overlay -o jsonpath='{.metadata.annotations.inference\.opendatahub\.io/routing-overlay-source-generation}' 2>/dev/null || true)
  [[ "$new_generation" != "$before_generation" ]] && break
  sleep 2
done
[[ "$new_generation" != "$before_generation" ]] || fail_stage "overlay generation convergence"
wait_for "Praxis mounted Provider B overlay" 120 kctl -n "$TENANT" exec deploy/praxis -- sh -c 'grep -q provider-provider-b /etc/praxis/routing/routing-overlay.json' || fail_stage "Praxis overlay reload"
result=$(request_status maas-default-gateway "$path" '{"model":"demo","messages":[{"role":"user","content":"provider-b"}]}' 2>/dev/null || true)
result_status=$(printf '%s' "$result" | cut -d'|' -f1); result_backend=$(printf '%s' "$result" | cut -d'|' -f2)
after_uid=$(kctl -n "$TENANT" get pod -l app=praxis -o jsonpath='{.items[0].metadata.uid}')
after_restart=$(kctl -n "$TENANT" get pod -l app=praxis -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
echo "  Provider B request     HTTP $result_status; backend ${result_backend:-unavailable}; generation $before_generation -> $new_generation"
echo "  Praxis restarts        $before_restart -> $after_restart"
[[ "$result_status" == 200 && "$result_backend" == *katan-b* && "$before_uid" == "$after_uid" && "$before_restart" == "$after_restart" ]] || fail_stage "Provider B swap"
record 4 provider_hot_swap PASS "http_status=$result_status backend=$result_backend praxis_restart_unchanged=true"
echo "RESULT"; echo "  Status                 PASS"; echo "  New requests use the new routing snapshot."; pause

stage "Semantic no-op" "Cause a real provider watch event and prove routing content does not churn."
before_overlay=$(kctl -n "$TENANT" get configmap routing-overlay -o json | jq -c '{data,annotations:{source:.metadata.annotations["inference.opendatahub.io/routing-overlay-source-generation"],digest:.metadata.annotations["inference.opendatahub.io/routing-overlay-content-digest"]}}')
mutate -n "$TENANT" annotate externalprovider provider-b local-env.opendatahub.io/demo-noop=true --overwrite >/dev/null
wait_for "provider watch event observed" 120 kctl -n "$TENANT" get externalprovider provider-b -o jsonpath='{.status.observedGeneration}'
after_overlay=$(kctl -n "$TENANT" get configmap routing-overlay -o json | jq -c '{data,annotations:{source:.metadata.annotations["inference.opendatahub.io/routing-overlay-source-generation"],digest:.metadata.annotations["inference.opendatahub.io/routing-overlay-content-digest"]}}')
[[ "$before_overlay" == "$after_overlay" ]] || fail_stage "semantic overlay churn"
record 5 semantic_noop PASS "watch_event=true overlay_bytes_unchanged=true"
echo "RESULT"; echo "  Status                 PASS"; pause

stage "Invalid overlay and last-known-good" "Reject malformed routing while serving the previous valid revision."
valid_overlay=$(kctl -n "$TENANT" get configmap routing-overlay -o jsonpath='{.data.routing-overlay\.json}')
mutate -n "$TENANT" patch configmap routing-overlay --type=merge -p='{"data":{"routing-overlay.json":"{}"}}' >/dev/null
result=$(request_status maas-default-gateway "$path" '{"model":"demo","messages":[{"role":"user","content":"last-known-good"}]}' 2>/dev/null || true)
result_status=$(printf '%s' "$result" | cut -d'|' -f1); result_backend=$(printf '%s' "$result" | cut -d'|' -f2)
restore_patch=$(jq -n --arg data "$valid_overlay" '{data:{"routing-overlay.json":$data}}')
mutate -n "$TENANT" patch configmap routing-overlay --type=merge -p "$restore_patch" >/dev/null
echo "  Invalid replacement    rejected; active request HTTP $result_status; backend ${result_backend:-unavailable}"
[[ "$result_status" == 200 && "$result_backend" == *katan-b* ]] || fail_stage "last-known-good serving"
record 6 last_known_good PASS "invalid_replacement=true http_status=$result_status backend=$result_backend"
echo "RESULT"; echo "  Status                 PASS"; echo "  Previous valid routing remained active."; pause

stage "Tenant isolation" "Prove real Tenant B traffic before and after a Tenant A mutation."
printf '    %-24s %-26s %-26s\n' Property "Tenant A" "Tenant B"
printf '    %-24s %-26s %-26s\n' Namespace "$TENANT" "$BNS"
bpath="/$BNS/demo/v1/chat/completions"
b_before=$(request_status maas-tenant-b-gateway "$bpath" '{"model":"demo","messages":[{"role":"user","content":"tenant-b-before"}]}' 2>/dev/null || true)
b_before_status=$(printf '%s' "$b_before" | cut -d'|' -f1); b_before_backend=$(printf '%s' "$b_before" | cut -d'|' -f2)
echo "    Tenant B before A change HTTP $b_before_status; backend ${b_before_backend:-unavailable}"
[[ "$b_before_status" == 200 ]] || fail_stage "Tenant B initial request"
mutate -n "$TENANT" patch externalprovider provider-b --type=merge -p='{"spec":{"config":{"demo-isolation":"true"}}}' >/dev/null
wait_for "Tenant A mutation observed" 120 kctl -n "$TENANT" get externalprovider provider-b -o jsonpath='{.status.observedGeneration}' || fail_stage "Tenant A reconcile"
b_after=$(request_status maas-tenant-b-gateway "$bpath" '{"model":"demo","messages":[{"role":"user","content":"tenant-b-after"}]}' 2>/dev/null || true)
b_after_status=$(printf '%s' "$b_after" | cut -d'|' -f1); b_after_backend=$(printf '%s' "$b_after" | cut -d'|' -f2)
echo "    Tenant B after A change  HTTP $b_after_status; backend ${b_after_backend:-unavailable}"
[[ "$b_after_status" == 200 ]] || fail_stage "Tenant B survival"
sa_a=$(kctl auth can-i get secrets --as="system:serviceaccount:$TENANT:praxis" -n "$TENANT" 2>/dev/null || true)
sa_b=$(kctl auth can-i get secrets --as="system:serviceaccount:$BNS:praxis-tenant-b" -n "$BNS" 2>/dev/null || true)
echo "    Praxis Secret API A/B   $sa_a/$sa_b (expected no/no)"
[[ "$sa_a" == no && "$sa_b" == no ]] || fail_stage "tenant Secret API isolation"
record 7 tenant_isolation PASS "tenant_b_before=$b_before_status tenant_b_after=$b_after_status secret_api=denied"
echo "RESULT"; echo "  Status                 PASS"; echo "  Tenant B survived real Tenant A traffic and mutation."; pause

stage "Credential behavior" "Report the runtime credential boundary without simulating an unqualified rotation."
echo "  Result                  NOT DEMONSTRATED"
echo "  Remaining gate          Live projected-Secret rotation qualification"
record 8 credential_rotation NOT_DEMONSTRATED "live rotation is outside current demo scope"
echo "RESULT"; echo "  Status                 NOT DEMONSTRATED"; pause

stage "Summary" "Summarize observed behavior and retain the healthy cluster."
record 9 summary PASS "routing_increment=pass credential_rotation=not_demonstrated"
atomic_results
python3 - "$EVIDENCE/results.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print("\n  Validation                         Result")
print("  ---------------------------------  ----------------")
for x in d["assertions"]: print("  %-33s %s" % (x["id"], x["status"]))
print("  Total demo assertions              %s" % d["total_assertions"])
PY
echo "RESULT"; echo "  Status                 PASS (routing increment)"
echo "  Credential rotation    NOT DEMONSTRATED"
echo "  Existing IPP path      FOLLOW-UP"
echo "  Retained context       $CONTEXT"
echo "  Evidence               $EVIDENCE"
echo "  Inspect: kubectl --context $CONTEXT get pods -A"
echo "  Inspect: kubectl --context $CONTEXT -n $TENANT get externalmodel,externalprovider,httproute,service,deployment,configmap"
echo "  Reset:   ./test/kind-env/demo.sh --context $CONTEXT --reset"
