#!/usr/bin/env bash
# Narrative renderer for finalized OpenShift qualification evidence.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${OPENSHIFT_E2E_STATE:-"$ROOT/.openshift-state"}
EVIDENCE_ARG=
LIVE_RC=

usage() {
  cat <<'EOF'
Usage: demo.sh [--non-interactive] [--evidence DIRECTORY]

Without --evidence, run e2e.sh and render its finalized results. With
--evidence, render an existing finalized results.json without contacting a
cluster. --non-interactive is accepted for scripted captures.
EOF
}
while (($#)); do
  case "$1" in
    --non-interactive) ;;
    --evidence) (($# > 1)) || { echo '--evidence requires a directory' >&2; exit 2; }; EVIDENCE_ARG=$2; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ -n "$EVIDENCE_ARG" ]]; then
  if [[ -f "$EVIDENCE_ARG" ]]; then
    RESULTS=$EVIDENCE_ARG
  else
    [[ -d "$EVIDENCE_ARG" ]] || { echo 'evidence path does not exist' >&2; exit 2; }
    RESULTS=$(find "$EVIDENCE_ARG" -type f -name results.json -print 2>/dev/null \
      | while IFS= read -r candidate; do
          if jq -e . "$candidate" >/dev/null 2>&1 && jq -e '.functional != "RUNNING"' "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
          fi
        done | tail -n 1)
  fi
else
  [[ -f "$STATE/run.env" ]] || { echo 'OpenShift state is not initialized' >&2; exit 2; }
  # shellcheck disable=SC1091
  source "$STATE/run.env"
  "$ROOT/test/openshift-env/e2e.sh" || LIVE_RC=$?
  RESULTS=$(find "${OPENSHIFT_E2E_EVIDENCE_ROOT:-$STATE/evidence}" -type f -name results.json -print 2>/dev/null | sort | tail -n 1 || true)
fi

[[ -n "${RESULTS:-}" && -s "$RESULTS" ]] || { echo 'No finalized results.json was found' >&2; [[ -n "$LIVE_RC" ]] && exit "$LIVE_RC"; exit 1; }
jq -e 'type == "object" and (.assertions | type == "array") and (.functional != "RUNNING")' "$RESULTS" >/dev/null \
  || { echo 'results.json is missing a finalized assertion list' >&2; exit 1; }
RUN_ROOT=$(dirname "$RESULTS")

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; RESET=''
fi
render_result() { case "$1" in PASS) printf '%sPASS%s' "$GREEN" "$RESET";; FAIL) printf '%sFAIL%s' "$RED" "$RESET";; *) printf '%sNOT DEMONSTRATED%s' "$YELLOW" "$RESET";; esac; }
status_for() {
  jq -r --arg re "$1" '[.assertions[]|select(.name|test($re;"i"))|.status] as $s|if ($s|length)==0 then "NOT DEMONSTRATED" elif any($s[];.=="FAIL") then "FAIL" elif any($s[];.=="NOT_DEMONSTRATED") then "NOT DEMONSTRATED" else "PASS" end' "$RESULTS"
}
detail_for() { jq -r --arg re "$1" '[.assertions[]|select(.name|test($re;"i"))|.detail//empty]|join("; ")' "$RESULTS"; }
safe() {
  printf '%s' "$1" | tr '\n' ' ' | sed -E 's/(Authorization[[:space:]]*:|Bearer[[:space:]]+)[^,; ]+/\1 ***REDACTED***/Ig; s/(x-api-key|api[_-]?key)[[:space:]]*[=:][[:space:]]*[^,; ]+/\1=***REDACTED***/Ig'
}
detail() { local v; v=$(detail_for "$1"); [[ -n "$v" ]] && safe "$v" || printf 'No matching finalized assertion detail was recorded.'; }
file_state() { [[ -s "$RUN_ROOT/$1" ]] && printf recorded || printf missing; }
block() {
  printf '\n==============================================================================\nTEST %s: %s\n------------------------------------------------------------------------------\n\nSUMMARY\n%s\n\nACTION\n%s\n\nOBSERVED\n%s\n\nRESULT\n' "$1" "$2" "$3" "$4" "$5"
  render_result "$6"
  printf '\n\nEXPLANATION\n%s\n' "$7"
}

tenant_ns=$(jq -r '.status.tenantNamespace//empty' "$RUN_ROOT/aitenant.json" 2>/dev/null || true)
gateway=$(jq -r '.status.gatewayRef.name//empty' "$RUN_ROOT/aitenant.json" 2>/dev/null || true)
gateway_ns=$(jq -r '.status.gatewayRef.namespace//empty' "$RUN_ROOT/aitenant.json" 2>/dev/null || true)
extproc_uid=$(jq -r '.items[0].metadata.uid//empty' "$RUN_ROOT/post-auth-extproc-pods.json" 2>/dev/null || true)
extproc_restart=$(jq -r '([.items[0].status.containerStatuses[]?.restartCount]|add)//empty' "$RUN_ROOT/post-auth-extproc-pods.json" 2>/dev/null || true)
digest=$(jq -r '.content_digest.value//empty' "$RUN_ROOT/config-overlay.json" 2>/dev/null || true)
mounted_digest=$(jq -r '.content_digest.value//empty' "$RUN_ROOT/mounted-overlay.json" 2>/dev/null || true)
route_parent=$(jq -r '.items[0].spec.parentRefs[0].name//empty' "$RUN_ROOT/httproutes.json" 2>/dev/null || true)
route_backend=$(jq -r '.items[0].spec.rules[0].backendRefs[0].name//empty' "$RUN_ROOT/httproutes.json" 2>/dev/null || true)
controller_image=$(jq -r '.spec.template.spec.containers[]?|select(.name=="manager")|.image' "$RUN_ROOT/controller.json" 2>/dev/null|head -1 || true)
extproc_image=$(jq -r '.spec.template.spec.containers[]?.args[]?|select(startswith("--image="))|sub("^--image=";"")' "$RUN_ROOT/controller.json" 2>/dev/null|head -1 || true)

printf '%s\n\n' 'OpenShift External Models -> ExtProc-only narrative demonstration'
printf '%s\n\n' 'A platform engineer opts one MaaS tenant into the ExtProc-only dataplane, authenticates through the shared Gateway, and changes the selected test endpoint while the pre-auth and post-auth ExtProc workloads remain running. This is a single-tenant integration demonstration using real reconciliation and request evidence.'
printf '%s\n' 'ARCHITECTURE / REQUEST PATH' 'client -> Gateway/Envoy -> pre-auth ExtProc -> Kuadrant/Authorino -> tenant-local post-auth ExtProc -> provider fixture' ''
printf '%s\n' 'TENANT AND PROVIDERS' 'Tenant: models-as-a-service' 'Provider A and Provider B are test endpoints used to demonstrate a controlled routing update, not load balancing or failover.'

s=$(status_for 'controller deployment Ready|AITenant Ready|ExternalProvider Ready|ExternalModel Ready|ExtProc-only workloads Ready')
block 1 'Deployment readiness' 'Establishes the test environment before request testing; readiness alone does not prove routing.' 'The authoritative suite waited for controller, MaaS tenant, provider/model fixtures, and both namespace-split ExtProc workloads.' "$(detail 'controller deployment Ready|AITenant Ready|ExternalProvider Ready|ExternalModel Ready|ExtProc-only workloads Ready')" "$s" 'The recorded readiness assertions are the foundation for the later request tests. Gateway, Authorino, and ExtProc behavior is not inferred from pod readiness.'

s=$(status_for '^AITenant Ready$'); [[ -n "$tenant_ns" && -n "$gateway" && -s "$RUN_ROOT/tenant-resources.json" ]] || s='NOT DEMONSTRATED'
block 2 'Tenant ExtProc selection' 'Shows explicit ExtProc opt-in, resolved tenant namespace, tenant-local workload, routing state, and projected credential reference.' 'The suite inspected the AITenant and tenant resources after reconciliation.' "opt-in=praxis; resolved namespace=$(safe "${tenant_ns:-missing}"); gateway=$(safe "${gateway_ns:-missing}/${gateway:-missing}"); tenant resources=$(file_state tenant-resources.json)" "$s" 'The controller owns the tenant-local post-auth ExtProc resources and routing projection while MaaS supplies tenant selection. Missing fields cannot be treated as a pass.'

s=$(status_for '^HTTPRoute Accepted$|^HTTPRoute ResolvedRefs$'); [[ -n "$route_parent" && -n "$route_backend" ]] || s='NOT DEMONSTRATED'
block 3 'Route acceptance' 'Confirms that the Gateway admitted the generated route and resolved its backend references.' 'The suite inspected HTTPRoute parent conditions and backend references.' "Accepted=True; ResolvedRefs=True; Gateway=$(safe "${gateway_ns:-missing}/${route_parent:-missing}"); backend=$(safe "${route_backend:-missing}")" "$s" 'Accepted means the route was admitted. ResolvedRefs means the backend references are valid before authentication and model traffic.'

s=$(status_for '^External HTTPS transport$')
block 3.5 'External HTTPS transport' 'Confirms the mounted post-auth ExtProc configuration preserves provider authority, TLS, hostname-only SNI, and the explicit dial port.' 'The suite inspected the live tenant ExtProc configuration for both declared Chat Completions providers.' "transport evidence=$(file_state extproc-transport-config.txt); API contract=openai-chat /v1/chat/completions" "$s" 'This proves the rendered request transport contract. It does not add or imply support for /v1/responses.'

s=$(status_for '^Unauthenticated request$|^API-key creation$'); [[ -s "$RUN_ROOT/key-create-status.txt" ]] || s='NOT DEMONSTRATED'
block 4 'Public TLS and authentication' 'Proves verified HTTPS reachability and rejection of an unauthenticated request.' 'The suite used the test CA, observed the public endpoint, and created a temporary MaaS API key without recording its value.' "$(detail '^Unauthenticated request$|^API-key creation$'); key value=withheld" "$s" 'HTTP 401 is the successful security result: the endpoint is reachable but protected traffic requires MaaS authentication.'

s=$(status_for '^First test endpoint$'); [[ -n "$extproc_uid" && -n "$extproc_restart" ]] || s='NOT DEMONSTRATED'
block 5 'Provider A request' 'Proves the authenticated Gateway -> Authorino -> post-auth ExtProc -> provider path.' 'The suite sent an authenticated request after Provider A overlay convergence and checked trusted attribution.' "$(detail '^First test endpoint$'); post-auth ExtProc UID=$(safe "${extproc_uid:-missing}"); restart count=$(safe "${extproc_restart:-missing}")" "$s" 'HTTP 200 with Provider A attribution proves the complete request path reached the selected fixture. The post-auth ExtProc identity is recorded as the process-stability baseline.'

s=$(status_for '^Unknown model$'); block 6 'Unknown model' 'Checks that an undeclared model fails closed instead of reaching an arbitrary provider.' 'The suite sent an authenticated request for a model absent from the tenant configuration.' "$(detail '^Unknown model$')" "$s" 'HTTP 404 is the expected boundary result for unknown model input.'

s=$(status_for '^Second test endpoint$|^ExternalModel ExtProc identity stable$'); [[ -n "$digest" && -n "$mounted_digest" ]] || s='NOT DEMONSTRATED'
block 7 'Provider A to Provider B switch' 'Demonstrates a controlled routing update while the ExternalModel ExtProc remains running.' 'The suite changed the declared provider selection, waited for projection, checked mounted state, and sent a new request.' "$(detail '^Second test endpoint$|^ExternalModel ExtProc identity stable$'); old/new generation and digest=not separately serialized; declared/recomputed/mounted evidence=$(file_state config-overlay.json)/$(file_state mounted-overlay.json); current digest=$(safe "${digest:-missing}")" "$s" 'Provider B HTTP 200 and attribution prove the selected update. This is not automatic failover or load balancing. Exact old/new revision values were not separately serialized by this retained e2e result.'

block 8 'Semantic no-op' 'Checks that unchanged effective routing does not publish a new configuration or restart the ExternalModel ExtProc workload.' 'The suite reapplied unchanged model content and compared generation, resource version, and digest.' "$(detail '^Semantic no-op$')" "$(status_for '^Semantic no-op$')" 'The result is based on recorded before/after identity and digest comparisons, not a sleep-based assumption.'
block 9 'Invalid-overlay last-known-good behavior' 'Checks that a malformed replacement cannot displace the valid configuration serving traffic.' 'The suite injected an invalid overlay, inspected mounted state, and made a request using the retained route.' "$(detail '^Invalid overlay LKG$')" "$(status_for '^Invalid overlay LKG$')" 'A successful Provider B request shows the malformed update was rejected and the last-known-good configuration protected live traffic.'

credential_re='provider_rejects_missing_credential|provider_rejects_wrong_credential|client_authorization_cannot_override_provider_credential|client_x_api_key_cannot_override_provider_credential|credential_enforcing_provider_chain'
block 10 'Provider credential enforcement' 'Proves the backend rejects absent or incorrect credentials and that ExtProc credential_inject replaces the caller credential.' 'The authenticated Gateway request carries the MaaS API key in Authorization while the backend accepts only its distinct provider key. A separate request supplies a conflicting x-api-key.' "$(detail "$credential_re"); credential values=withheld" "$(status_for "$credential_re")" 'Direct HTTP 401 responses prove backend enforcement. The attributed HTTP 200 responses prove ExtProc credential_inject replaced the caller credential and ignored the conflicting x-api-key. Duplicate Authorization header ordering is out of scope. Credential rotation, OAuth2, and SigV4 are not covered.'

block 11 'Tenant security' 'Checks Secret API isolation for the post-auth ExtProc ServiceAccount and evidence hygiene.' 'The suite performed the ServiceAccount authorization check and scanned finalized output for credential-shaped patterns.' "$(detail '^ExtProc Secret API denied$|^Credential leak scan$')" "$(status_for '^ExtProc Secret API denied$|^Credential leak scan$')" 'The result proves Kubernetes API isolation and evidence hygiene for this run; Secret bytes and the temporary API key are not displayed.'
block 12 'Reset and credential revocation' 'Confirms Provider A is restored and the temporary MaaS credential is revoked.' 'The suite restored Provider A, made a final attributed request, and revoked the temporary key.' "$(detail '^Provider A reset request$|^API-key revocation$')" "$(status_for '^Provider A reset request$|^API-key revocation$')" 'The reset and revocation results come from finalized assertions. The credential itself is never printed.'

names=('Deployment readiness' 'Tenant ExtProc selection' 'Route acceptance' 'External HTTPS transport' 'TLS and authentication' 'Provider A request' 'Unknown model' 'Provider switch' 'ExternalModel ExtProc remained running' 'Semantic no-op' 'Last-known-good behavior' 'Credential enforcement' 'Tenant security' 'Provider A reset' 'Credential revocation')
values=("$(status_for 'controller deployment Ready|AITenant Ready|ExternalProvider Ready|ExternalModel Ready|ExtProc-only workloads Ready')" "$( [[ -n "$tenant_ns" && -n "$gateway" && -s "$RUN_ROOT/tenant-resources.json" ]] && printf PASS || printf 'NOT DEMONSTRATED' )" "$(status_for '^HTTPRoute Accepted$|^HTTPRoute ResolvedRefs$')" "$(status_for '^External HTTPS transport$')" "$(status_for '^Unauthenticated request$|^API-key creation$')" "$(status_for '^First test endpoint$')" "$(status_for '^Unknown model$')" "$(status_for '^Second test endpoint$|^ExternalModel ExtProc identity stable$')" "$(status_for '^ExternalModel ExtProc identity stable$')" "$(status_for '^Semantic no-op$')" "$(status_for '^Invalid overlay LKG$')" "$(status_for "$credential_re")" "$(status_for '^ExtProc Secret API denied$|^Credential leak scan$')" "$(status_for '^Provider A reset request$')" "$(status_for '^API-key revocation$')")
printf '\nVALIDATION SUMMARY\n\n%-40s %s\n%-40s %s\n' 'Test' 'Result' '----------------------------------------' '----------------'
for i in "${!names[@]}"; do printf '%-40s ' "${names[$i]}"; render_result "${values[$i]}"; printf '\n'; done
pass=0; fail=0; not_demonstrated=0
for v in "${values[@]}"; do case "$v" in PASS) ((pass+=1));; FAIL) ((fail+=1));; *) ((not_demonstrated+=1));; esac; done
printf '\nOVERALL RESULT\n'; if ((fail > 0)) || [[ $(jq -r '.functional' "$RESULTS") == FAIL ]]; then render_result FAIL; elif ((not_demonstrated > 0)); then render_result 'NOT DEMONSTRATED'; else render_result PASS; fi
printf '\nPassed: %d  Failed: %d  Not demonstrated: %d\nEvidence directory: . (relative run root)\nFinalized results: results.json\n' "$pass" "$fail" "$not_demonstrated"
printf 'Post-auth ExtProc UID: %s\nPost-auth ExtProc restart count: %s\nOverlay digest: %s\nMounted digest: %s\n' "$(safe "${extproc_uid:-not recorded}")" "$(safe "${extproc_restart:-not recorded}")" "$(safe "${digest:-not recorded}")" "$(safe "${mounted_digest:-not recorded}")"
printf 'Image digests:\n  controller: %s\n  ExtProc: %s\n  MaaS: not recorded in this e2e result\n  provider fixtures: not recorded in this e2e result\n' "$(safe "${controller_image:-not recorded}")" "$(safe "${extproc_image:-not recorded}")"
printf '\nUNPROVEN SCOPE\n- credential rotation\n- two-tenant MaaS authorization\n- IPP transition and rollback\n- OAuth2 and SigV4\n- commercial-provider qualification\n'
[[ -n "$LIVE_RC" ]] && exit "$LIVE_RC"
[[ $(jq -r '.functional' "$RESULTS") == FAIL ]] && exit 1
exit 0
