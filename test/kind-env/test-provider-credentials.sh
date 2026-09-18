#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
BACKENDS="$ROOT/test/kind-env/manifests/00-backends.yaml"
TRANSITION="$ROOT/test/kind-env/manifests/42-transition-fixtures.yaml"
CONTEXT=

usage() {
  echo "usage: $0 [--context kubectl-context]" >&2
}

while (($#)); do
  case "$1" in
    --context)
      (($# >= 2)) || { usage; exit 2; }
      CONTEXT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

command -v yq >/dev/null 2>&1 || { echo "yq is required" >&2; exit 2; }
KCTL=(kubectl)
if [[ -n "$CONTEXT" ]]; then
  KCTL+=(--context "$CONTEXT")
fi

manifest_args() {
  local deployment=$1
  yq -r "select(.kind == \"Deployment\" and .metadata.name == \"$deployment\") | .spec.template.spec.containers[0].args | join(\" \")" "$BACKENDS"
}

assert_enforcement_args() {
  local deployment=$1 expected=$2 args=$3 source=$4
  [[ "$args" == *"--validate-keys"* ]] || { echo "$source $deployment does not enforce API keys" >&2; return 1; }
  [[ "$args" == *"--api-keys"*"openai=$expected"* ]] || { echo "$source $deployment has the wrong Katan fixture key" >&2; return 1; }
}

for deployment in katan-a katan-b katan-a-tenant-b katan-b-tenant-b; do
  args=$(manifest_args "$deployment")
  expected=kind-only-dummy
  [[ "$deployment" == *-tenant-b ]] && expected=tenant-b-controller-only-reference
  assert_enforcement_args "$deployment" "$expected" "$args" manifest || exit 1
done

transition_args=$(manifest_args katan-transition)
assert_enforcement_args katan-transition transition-provider-key "$transition_args" manifest || exit 1
[[ "$(yq -r 'select(.kind == "Secret" and .metadata.name == "transition-provider-credentials") | .stringData["api-key"]' "$TRANSITION")" == transition-provider-key ]] || { echo "transition Secret does not match its backend" >&2; exit 1; }
[[ "$(yq -r 'select(.kind == "Service" and .metadata.name == "provider-a-legacy") | .spec.selector.app' "$BACKENDS")" == katan-transition ]] || { echo "IPP compatibility Service is not isolated" >&2; exit 1; }

if rg -n 'llm-katan(:|@)' "$BACKENDS" | rg -v '@sha256:' >/dev/null; then
  echo "a backend image is not pinned by digest" >&2
  exit 1
fi

if [[ -z "$CONTEXT" ]]; then
  echo "provider credential fixture manifest checks passed (live checks skipped; use --context for live validation)"
  exit 0
fi

live_args() {
  local deployment=$1
  "${KCTL[@]}" -n maas-system get deployment "$deployment" \
    -o jsonpath='{.spec.template.spec.containers[0].args[*]}'
}

for deployment in katan-a katan-b katan-a-tenant-b katan-b-tenant-b; do
  expected=kind-only-dummy
  [[ "$deployment" == *-tenant-b ]] && expected=tenant-b-controller-only-reference
  live=$(live_args "$deployment")
  assert_enforcement_args "$deployment" "$expected" "$live" live || exit 1
done
live_transition=$(live_args katan-transition)
assert_enforcement_args katan-transition transition-provider-key "$live_transition" live || exit 1

command -v curl >/dev/null 2>&1 || { echo "curl is required for live checks" >&2; exit 2; }
provider_body='{"model":"demo","messages":[{"role":"user","content":"credential-fixture"}]}'
pf_pids=()
cleanup() {
  for pid in "${pf_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap cleanup EXIT

start_port_forward() {
  local service=$1 local_port=$2 remote_port=$3 log
  log=$(mktemp)
  "${KCTL[@]}" -n maas-system port-forward "service/$service" "$local_port:$remote_port" >"$log" 2>&1 &
  pf_pids+=("$!")
  for _ in $(seq 1 30); do
    if rg -q 'Forwarding from' "$log"; then
      rm -f "$log"
      return 0
    fi
    sleep 0.2
  done
  rm -f "$log"
  echo "timed out waiting for port-forward service/$service" >&2
  return 1
}

probe_service() {
  local service=$1 port=$2 remote_port=$3 expected=$4 label=$5
  start_port_forward "$service" "$port" "$remote_port"
  local url="http://127.0.0.1:$port/v1/chat/completions"
  local missing wrong accepted x_api_key
  missing=$(curl --noproxy '*' --connect-timeout 3 --max-time 10 -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' --data "$provider_body" "$url" || echo 000)
  wrong=$(curl --noproxy '*' --connect-timeout 3 --max-time 10 -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' -H 'Authorization: Bearer fixture-wrong' --data "$provider_body" "$url" || echo 000)
  accepted=$(curl --noproxy '*' --connect-timeout 3 --max-time 10 -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' -H "Authorization: Bearer $expected" --data "$provider_body" "$url" || echo 000)
  x_api_key=$(curl --noproxy '*' --connect-timeout 3 --max-time 10 -sS -o /dev/null -w '%{http_code}' \
    -H 'content-type: application/json' -H "Authorization: Bearer $expected" -H 'x-api-key: fixture-wrong' \
    --data "$provider_body" "$url" || echo 000)
  [[ "$missing" == 401 && "$wrong" == 401 && "$accepted" == 200 && "$x_api_key" == 200 ]] || {
    echo "$label direct credential checks failed: missing=$missing wrong=$wrong accepted=$accepted x_api_key=$x_api_key" >&2
    return 1
  }
  echo "$label direct checks: missing=401 wrong=401 expected=200 x-api-key-with-expected=200"
}

probe_service provider-a 18080 8000 kind-only-dummy provider-a
probe_service provider-b 18081 8000 kind-only-dummy provider-b
probe_service provider-a-legacy 18082 443 transition-provider-key transition
echo "provider credential fixture manifest, live-argument, and direct enforcement checks passed"
