#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/test/openshift-env/lib.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/fake-oc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == exec && "$2" == -i ]] || exit 1
shift 2
while [[ "$1" != -- ]]; do shift; done
shift
[[ "$1" == sh && "$2" == -c ]] || exit 1
shift 3
ca=''
url=''
while (($#)); do
  case "$1" in
    --cacert) ca=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
key=$(IFS= read -r line && printf '%s' "$line")
body=$(IFS= read -r line && printf '%s' "$line")
printf 'url=%s\nca=%s\nkey=%s\nbody=%s\n' "$url" "$ca" "$key" "$body"
EOF
chmod 700 "$TMP/fake-oc"
OC=("$TMP/fake-oc")
CLIENT=test-client
OPENSHIFT_E2E_TENANT_NAMESPACE=test-tenant
CA_FILE=/etc/xmp/ca/ca.crt
output=$(client_post_with_key 'opaque-test-key' 'https://gateway.example.test/test-tenant/gpt-4o-mini/v1/chat/completions' '{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}]}')
grep -Fxq 'url=https://gateway.example.test/test-tenant/gpt-4o-mini/v1/chat/completions' <<<"$output"
grep -Fxq 'ca=/etc/xmp/ca/ca.crt' <<<"$output"
grep -Fxq 'key=opaque-test-key' <<<"$output"
grep -Fxq 'body={"model":"gpt-4o-mini","messages":[{"role":"user","content":"Hello"}]}' <<<"$output"
echo 'request-wrapper: PASS'
