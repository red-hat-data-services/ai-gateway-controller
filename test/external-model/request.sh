#!/usr/bin/env bash

# Shared credential-safe request helper for the persistent in-cluster client.
# The caller pipes exactly two newline-delimited values to this function:
# the ephemeral MaaS key and one-line JSON request body. Neither value is a
# function argument or written to host evidence.

external_model_client_post() {
  local url=$1
  local ca_file=${2:-}
  [[ -n "${EXTERNAL_MODEL_CLIENT_EXEC:-}" ]] || {
    echo 'EXTERNAL_MODEL_CLIENT_EXEC must name an adapter function' >&2
    return 2
  }
  local output=${EXTERNAL_MODEL_CLIENT_OUTPUT:-/dev/null}
  local curl_args=(--connect-timeout 5 --max-time 60 --silent --show-error --output "$output" --write-out '%{http_code}' -X POST "$url" -H 'Content-Type: application/json')
  if [[ -n "$ca_file" ]]; then
    curl_args+=(--cacert "$ca_file")
  fi
  # The inner shell expands key/body after they are read from stdin.
  # shellcheck disable=SC2016,SC2086
  "$EXTERNAL_MODEL_CLIENT_EXEC" sh -c '
    IFS= read -r key || exit 2
    IFS= read -r body || exit 2
    curl "$@" -H "Authorization: Bearer $key" --data-binary "$body"
  ' sh "${curl_args[@]}"
}
