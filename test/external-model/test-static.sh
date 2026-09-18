#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
command -v yq >/dev/null 2>&1 || { echo 'yq is required' >&2; exit 2; }

for file in "$ROOT/test/external-model"/*.yaml.tmpl; do
  yq eval '.' "$file" >/dev/null
done

openai="$ROOT/test/external-model/openai.yaml.tmpl"
yq -e 'select(.kind == "ExternalModel") | .spec.modelName == "gpt-4o-mini" and .spec.externalProviderRefs[0].targetModel == "gpt-4o-mini" and .spec.externalProviderRefs[0].apiFormat == "openai-chat" and .spec.externalProviderRefs[0].path == "/v1/chat/completions"' "$openai" >/dev/null
yq -e 'select(.kind == "MaaSModelRef") | .metadata.name == "gpt-4o-mini" and .spec.modelRef.name == "openai-gpt-4o-mini"' "$openai" >/dev/null
yq -e 'select(.kind == "MaaSSubscription") | .spec.modelRefs[0].name == "gpt-4o-mini"' "$openai" >/dev/null
yq -e 'select(.kind == "MaaSAuthPolicy") | .spec.modelRefs[0].name == "gpt-4o-mini"' "$openai" >/dev/null

if rg -n 'stringData:|data:.*api-key|Bearer [A-Za-z0-9._-]{12,}|sk-[A-Za-z0-9]' "$ROOT/test/external-model"/*.yaml.tmpl; then
  echo 'shared resources contain credential-shaped data' >&2
  exit 1
fi
rg -q -- '--validate-keys' "$ROOT/test/kind-env/manifests/00-backends.yaml"
rg -q -- '--api-keys' "$ROOT/test/kind-env/manifests/00-backends.yaml"
rg -q -- '--validate-keys' "$ROOT/test/openshift-env/manifests/30-provider-fixtures.yaml.tmpl"
rg -q -- '--api-keys' "$ROOT/test/openshift-env/manifests/30-provider-fixtures.yaml.tmpl"
rg -q -- '--praxis-plaintext-cluster=provider-provider-a' "$ROOT/test/kind-env/run.sh"
rg -q -- '--tls-cert' "$ROOT/test/openshift-env/manifests/30-provider-fixtures.yaml.tmpl"
rg -q 'port: 443' "$ROOT/test/openshift-env/manifests/30-provider-fixtures.yaml.tmpl"

if rg -n '^kind:\s*Tenant\b|selection_group|equal[-_ ]weight|random selection|100-request distribution' \
  "$ROOT/test/external-model"/*.yaml.tmpl "$ROOT/test/kind-env/manifests" "$ROOT/test/openshift-env/manifests"; then
  echo 'unsupported Tenant or equal-weight/random-selection content found in base harness' >&2
  exit 1
fi
if rg -n -i 'default[-_ ]tenant|defaulttenant' "$ROOT/test/openshift-env"; then
  echo 'stale default-tenant terminology remains in the OpenShift harness' >&2
  exit 1
fi

echo 'external-model shared-resource checks: PASS'
