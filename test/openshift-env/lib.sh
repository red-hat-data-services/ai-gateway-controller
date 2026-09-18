#!/usr/bin/env bash
# shellcheck disable=SC2016

# OpenShift adapter for the shared in-cluster request helper. Secrets are
# supplied on stdin and the helper never receives the MaaS key as an argument.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/test/external-model/request.sh"

external_model_client_exec() {
  "${OC[@]}" exec -i "$CLIENT" -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -- "$@"
}

client_post_with_key() {
  local key=$1 url=$2 body=$3
  EXTERNAL_MODEL_CLIENT_EXEC=external_model_client_exec
  export EXTERNAL_MODEL_CLIENT_EXEC
  # shellcheck disable=SC2153
  printf '%s\n%s\n' "$key" "$body" | external_model_client_post "$url" "$CA_FILE"
}
