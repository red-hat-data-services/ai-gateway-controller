#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${OPENSHIFT_E2E_STATE:-"$ROOT/.openshift-state"}
# shellcheck disable=SC1091
source "$STATE/run.env"
OC=(oc --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}")
OUT="$OPENSHIFT_E2E_EVIDENCE_ROOT/provision"
mkdir -p "$OUT"
OPENSHIFT_E2E_GATEWAY_TLS_SECRET="xmp-gateway-tls-$OPENSHIFT_E2E_RUN_ID"
OPENSHIFT_E2E_GATEWAY_CLASS="${OPENSHIFT_E2E_GATEWAY_CLASS:-}"
AITENANT_NAME="${OPENSHIFT_E2E_AITENANT_NAME:-models-as-a-service}"
OPENSHIFT_E2E_USER="${OPENSHIFT_E2E_USER:-$("${OC[@]}" whoami)}"

need() { command -v "$1" >/dev/null || { echo "$1 is required" >&2; exit 1; }; }
need docker
need skopeo
need sha256sum
need envsubst
REQUESTED_CONTROLLER_IMAGE="${OPENSHIFT_E2E_CONTROLLER_IMAGE:-}"
[[ -n "${PRAXIS_REPO:-}" && -n "${PRAXIS_EXTPROC_REPO:-}" && -n "${MAAS_CONTROLLER_REPO:-}" && -n "${KSERVE_REPO:-}" && -n "${KUADRANT_OPERATOR_REPO:-}" ]] || {
  echo "PRAXIS_REPO, PRAXIS_EXTPROC_REPO, MAAS_CONTROLLER_REPO, KSERVE_REPO, and KUADRANT_OPERATOR_REPO must point to pinned clean checkouts" >&2
  exit 1
}
repos=("$PRAXIS_EXTPROC_REPO")
for repo in "${repos[@]}"; do
  git -C "$repo" diff --quiet || { echo "refusing dirty dependency source: $repo" >&2; exit 1; }
  git -C "$repo" diff --cached --quiet || { echo "refusing staged dependency source: $repo" >&2; exit 1; }
done
git -C "$MAAS_CONTROLLER_REPO" diff --quiet || { echo "refusing dirty MaaS source: $MAAS_CONTROLLER_REPO" >&2; exit 1; }
git -C "$MAAS_CONTROLLER_REPO" diff --cached --quiet || { echo "refusing staged MaaS source: $MAAS_CONTROLLER_REPO" >&2; exit 1; }
RESOLVED_CONTROLLER_IMAGE=""
if [[ -n "$REQUESTED_CONTROLLER_IMAGE" ]]; then
  if [[ "$REQUESTED_CONTROLLER_IMAGE" == *@sha256:* ]]; then
    RESOLVED_CONTROLLER_IMAGE="$REQUESTED_CONTROLLER_IMAGE"
  else
    CONTROLLER_DIGEST=$(skopeo inspect "docker://$REQUESTED_CONTROLLER_IMAGE" 2>"$OUT/controller-image-resolve.err" | jq -er '.Digest') || {
      echo "unable to resolve explicit controller image to an immutable digest: $REQUESTED_CONTROLLER_IMAGE; diagnostics: $OUT/controller-image-resolve.err" >&2
      exit 1
    }
    RESOLVED_CONTROLLER_IMAGE="${REQUESTED_CONTROLLER_IMAGE%:*}@$CONTROLLER_DIGEST"
  fi
fi
"$ROOT/test/openshift-env/bootstrap.sh"
if [[ -z "$OPENSHIFT_E2E_GATEWAY_CLASS" ]]; then
  OPENSHIFT_E2E_GATEWAY_CLASS=$(cat "$STATE/istio-gateway-class.txt" 2>/dev/null || true)
fi
[[ -n "$OPENSHIFT_E2E_GATEWAY_CLASS" ]] || {
  echo 'bootstrap did not resolve an OpenShift GatewayClass and no explicit OPENSHIFT_E2E_GATEWAY_CLASS was supplied' >&2
  exit 1
}
{
  printf 'controller_head '; git -C "$ROOT" rev-parse HEAD
  printf 'controller_worktree_diff '; git -C "$ROOT" diff HEAD --binary | sha256sum
  printf 'praxis_head '; git -C "$PRAXIS_REPO" rev-parse HEAD
  printf 'praxis_worktree_diff '; git -C "$PRAXIS_REPO" diff HEAD --binary | sha256sum
  printf 'extproc_head '; git -C "$PRAXIS_EXTPROC_REPO" rev-parse HEAD
  printf 'katan_source_commit a5a47568ac6daf1d4bd8b356e7b350cce9ceca2a\n'
} >"$OUT/source-shas.txt"

check_run_ns() {
  local ns=$1
  if "${OC[@]}" get namespace "$ns" >/dev/null 2>&1; then
    local owner
    owner=$("${OC[@]}" get namespace "$ns" -o jsonpath='{.metadata.labels.external-model-praxis\.opendatahub\.io/run-id}' 2>/dev/null || true)
    [[ "$owner" == "$OPENSHIFT_E2E_RUN_ID" ]] || { echo "refusing to reuse foreign namespace: $ns" >&2; exit 1; }
  fi
}
ensure_shared_ns() {
  local ns=$1
  if ! "${OC[@]}" get namespace "$ns" >/dev/null 2>&1; then
    "${OC[@]}" create namespace "$ns" >/dev/null
  fi
}
apply_rendered() {
  local file=$1
  local dry_run="$OUT/server-dry-run-${file%.yaml}.log"
  local apply_log="$OUT/apply-${file%.yaml}.log"
  timeout 120s "${OC[@]}" apply --dry-run=server --validate=true -f "$RENDER_DIR/$file" >"$dry_run" 2>&1
  timeout 120s "${OC[@]}" apply -f "$RENDER_DIR/$file" >"$apply_log" 2>&1
}
check_run_ns "$OPENSHIFT_E2E_CONTROLLER_NAMESPACE"
check_run_ns "$OPENSHIFT_E2E_BACKEND_NAMESPACE"
ensure_shared_ns maas-system
ensure_shared_ns ai-tenants
RENDER_DIR="$OUT/rendered-manifests"
export OPENSHIFT_E2E_RUN_ID OPENSHIFT_E2E_CONTROLLER_NAMESPACE OPENSHIFT_E2E_BACKEND_NAMESPACE
export OPENSHIFT_E2E_TENANT_NAMESPACE OPENSHIFT_E2E_GATEWAY_NAME OPENSHIFT_E2E_GATEWAY_NAMESPACE OPENSHIFT_E2E_GATEWAY_CLASS
export OPENSHIFT_E2E_GATEWAY_TLS_SECRET
# Install the controller's additive development/test CRD package before any
# fixture is created.  The controller writes observedGeneration and overlay
# attestations declared by these schemas; relying on a pre-existing CRD leaves
# those writes silently pruned on clusters with an older schema.
kustomize build "$ROOT/config/crd" | "${OC[@]}" apply --server-side -f - >"$OUT/controller-crds.log" 2>&1
"$ROOT/test/openshift-env/render-manifests.sh" "$RENDER_DIR" \
  00-namespaces.yaml.tmpl 05-image-puller.yaml.tmpl 10-gateway.yaml.tmpl >"$OUT/render-manifests-initial.log"
apply_rendered 00-namespaces.yaml
apply_rendered 05-image-puller.yaml
apply_rendered 10-gateway.yaml

# The Gateway address is assigned by the real OpenShift load balancer. Create
# a run-owned certificate for that address, then let Istio reprogram the
# listener. The private key is never written to evidence or command output.
# The Gateway address is assigned asynchronously by the real OpenShift load
# balancer. Wait on observed status before generating a certificate whose SAN
# contains that exact hostname; never guess the endpoint.
GATEWAY_DEADLINE=$((SECONDS + 300))
GATEWAY_HOST=""
while [[ -z "$GATEWAY_HOST" ]]; do
  GATEWAY_HOST=$("${OC[@]}" get gateway "$OPENSHIFT_E2E_GATEWAY_NAME" -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
  [[ -n "$GATEWAY_HOST" ]] && break
  if (( SECONDS >= GATEWAY_DEADLINE )); then
    "${OC[@]}" get gateway "$OPENSHIFT_E2E_GATEWAY_NAME" -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" -o json >"$OUT/gateway-address-timeout.json" 2>&1 || true
    echo "Gateway did not receive an address within 300s; diagnostics: $OUT/gateway-address-timeout.json" >&2
    exit 1
  fi
  sleep 2
done
"${OC[@]}" get gateway "$OPENSHIFT_E2E_GATEWAY_NAME" -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" -o json >"$OUT/gateway-before-certificate.json"
TLS_DIR=$(mktemp -d "$STATE/.gateway-tls.XXXXXX")
openssl req -x509 -nodes -newkey rsa:2048 -days 2 \
  -subj "/CN=external-model-praxis" -addext "subjectAltName=DNS:$GATEWAY_HOST" \
  -keyout "$TLS_DIR/tls.key" -out "$TLS_DIR/tls.crt" >"$OUT/gateway-certificate-generation.log" 2>&1
"${OC[@]}" create secret tls "$OPENSHIFT_E2E_GATEWAY_TLS_SECRET" -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" \
  --cert="$TLS_DIR/tls.crt" --key="$TLS_DIR/tls.key" \
  --dry-run=client -o yaml | sed '/^  creationTimestamp:/d' | "${OC[@]}" apply -f - >"$OUT/gateway-tls-secret.log" 2>&1
"${OC[@]}" label secret "$OPENSHIFT_E2E_GATEWAY_TLS_SECRET" -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" \
  external-model-praxis.opendatahub.io/run-id="$OPENSHIFT_E2E_RUN_ID" \
  app.kubernetes.io/managed-by=external-model-praxis-openshift-e2e --overwrite >/dev/null
rm -rf "$TLS_DIR"

REGISTRY=${OPENSHIFT_E2E_REGISTRY:-$(cat "$OUT/../bootstrap/registry-host.txt")}
REGISTRY=${REGISTRY#https://}
REGISTRY=${REGISTRY%/}
IMAGE_PROJECT=${OPENSHIFT_E2E_IMAGE_PROJECT:-$OPENSHIFT_E2E_BACKEND_NAMESPACE}
PULL_REGISTRY="image-registry.openshift-image-registry.svc:5000"
PULL_SECRET="xmp-registry-pull-$OPENSHIFT_E2E_RUN_ID"
CONTROLLER_IMAGE="${RESOLVED_CONTROLLER_IMAGE:-$PULL_REGISTRY/$IMAGE_PROJECT/ai-gateway-controller:$OPENSHIFT_E2E_RUN_ID}"
PRAXIS_IMAGE="$PULL_REGISTRY/$IMAGE_PROJECT/praxis-ai:$OPENSHIFT_E2E_RUN_ID"
EXTPROC_IMAGE="$PULL_REGISTRY/$IMAGE_PROJECT/praxis-extproc:$OPENSHIFT_E2E_RUN_ID"
KATAN_IMAGE="${KATAN_IMAGE:-ghcr.io/nerdalert/llm-katan@sha256:11379a1ec2fd69dc121eada6c544eb423a7c074414507dc1d474f4abba9df75a}"
MAAS_API_IMAGE="$PULL_REGISTRY/$IMAGE_PROJECT/maas-api:$OPENSHIFT_E2E_RUN_ID"
MAAS_CONTROLLER_IMAGE="$PULL_REGISTRY/$IMAGE_PROJECT/maas-controller:$OPENSHIFT_E2E_RUN_ID"

TOKEN=$("${OC[@]}" whoami -t)
AUTHFILE=$(mktemp "$STATE/.registry-auth.XXXXXX")
CLIENT_CA_FILE=""
PROVIDER_CA_BUNDLE=""
PROVIDER_CA_SERVICE=""
cleanup_temp_files() {
  local file
  for file in "$AUTHFILE" "$CLIENT_CA_FILE" "$PROVIDER_CA_BUNDLE" "$PROVIDER_CA_SERVICE"; do
    [[ -z "$file" ]] || rm -f -- "$file"
  done
}
trap cleanup_temp_files EXIT
rm -f "$AUTHFILE"
REGISTRY_CERT_DIR=$(mktemp -d "$STATE/.registry-ca.XXXXXX")
"${OC[@]}" get secret router-ca -n openshift-ingress-operator -o jsonpath='{.data.tls\.crt}' | base64 -d >"$REGISTRY_CERT_DIR/ca.crt"
printf '%s\n' "$TOKEN" | skopeo login --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --authfile "$AUTHFILE" --username unused --password-stdin "$REGISTRY" >"$OUT/registry-login.txt" 2>&1
PULL_AUTHFILE=$(mktemp "$STATE/.pull-auth.XXXXXX")
rm -f "$PULL_AUTHFILE"
"${OC[@]}" registry login --registry="$PULL_REGISTRY" --to="$PULL_AUTHFILE" >"$OUT/registry-pull-login.txt" 2>&1
for namespace in "$OPENSHIFT_E2E_CONTROLLER_NAMESPACE" "$OPENSHIFT_E2E_BACKEND_NAMESPACE" maas-system; do
  "${OC[@]}" create secret generic "$PULL_SECRET" -n "$namespace" --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$PULL_AUTHFILE" --dry-run=client -o yaml | "${OC[@]}" apply -f - >"$OUT/registry-pull-secret-$namespace.log" 2>&1
  "${OC[@]}" label secret "$PULL_SECRET" -n "$namespace" --overwrite \
    "external-model-praxis.opendatahub.io/run-id=$OPENSHIFT_E2E_RUN_ID" \
    app.kubernetes.io/managed-by=external-model-praxis-openshift-e2e >>"$OUT/registry-pull-secret-$namespace.log" 2>&1
done
attach_pull_secret_to_sa() {
  local namespace=$1 sa=$2 current snapshot patch
  current=$("${OC[@]}" get serviceaccount "$sa" -n "$namespace" -o json)
  snapshot="$STATE/serviceaccount-original-${namespace}-${sa}.json"
  if [[ ! -s "$snapshot" ]]; then
    jq '{namespace:.metadata.namespace,name:.metadata.name,uid:.metadata.uid,imagePullSecrets:(.imagePullSecrets // null)}' <<<"$current" >"$snapshot"
  fi
  patch=$(jq -cn --arg name "$PULL_SECRET" --argjson current "$(jq '.imagePullSecrets // []' <<<"$current")" \
    '{imagePullSecrets:($current + [{name:$name}] | unique_by(.name))}')
  "${OC[@]}" patch serviceaccount "$sa" -n "$namespace" --type=merge -p "$patch" >/dev/null
}
rm -f "$PULL_AUTHFILE"
unset TOKEN
BUILD_FLAGS=(--platform linux/amd64 --provenance=false --sbom=false)
BUILD_IMAGES=("$CONTROLLER_IMAGE" "$PRAXIS_IMAGE" "$EXTPROC_IMAGE" "$MAAS_API_IMAGE" "$MAAS_CONTROLLER_IMAGE")
CONTROLLER_IMAGE_EXTERNAL=false
[[ "$CONTROLLER_IMAGE" == *@sha256:* ]] && CONTROLLER_IMAGE_EXTERNAL=true
if [[ -n "$REQUESTED_CONTROLLER_IMAGE" ]]; then
  printf 'requested=%s\nresolved=%s\n' "$REQUESTED_CONTROLLER_IMAGE" "$CONTROLLER_IMAGE" >"$OUT/controller-image-provenance.txt"
fi
if [[ "${OPENSHIFT_E2E_REUSE_BUILT_IMAGES:-false}" == true ]]; then
  for image in "${BUILD_IMAGES[@]}"; do
    [[ "$image" == *@sha256:* ]] && continue
    docker image inspect "$image" >/dev/null 2>&1 || { echo "requested image reuse but local image is missing: $image" >&2; exit 1; }
  done
  printf '%s\n' "reusing prebuilt local images" >"$OUT/build-reused.txt"
else
  if [[ "$CONTROLLER_IMAGE_EXTERNAL" == false ]]; then
    docker build "${BUILD_FLAGS[@]}" -t "$CONTROLLER_IMAGE" "$ROOT" >"$OUT/build-controller.log" 2>&1
  else
    printf 'using externally supplied digest-pinned controller image: %s\n' "$CONTROLLER_IMAGE" >"$OUT/build-controller.log"
  fi
  docker build "${BUILD_FLAGS[@]}" -t "$PRAXIS_IMAGE" -f "$PRAXIS_REPO/Containerfile" "$PRAXIS_REPO" >"$OUT/build-praxis.log" 2>&1
  docker build "${BUILD_FLAGS[@]}" -t "$EXTPROC_IMAGE" -f "$PRAXIS_EXTPROC_REPO/Containerfile" "$PRAXIS_EXTPROC_REPO" >"$OUT/build-extproc.log" 2>&1
  docker build "${BUILD_FLAGS[@]}" -t "$MAAS_API_IMAGE" -f "$MAAS_CONTROLLER_REPO/maas-api/Dockerfile" "$MAAS_CONTROLLER_REPO/maas-api" >"$OUT/build-maas-api.log" 2>&1
  docker build "${BUILD_FLAGS[@]}" -t "$MAAS_CONTROLLER_IMAGE" -f "$MAAS_CONTROLLER_REPO/maas-controller/Dockerfile" "$MAAS_CONTROLLER_REPO" >"$OUT/build-maas-controller.log" 2>&1
fi
for image in "$CONTROLLER_IMAGE" "$PRAXIS_IMAGE" "$EXTPROC_IMAGE" "$MAAS_API_IMAGE" "$MAAS_CONTROLLER_IMAGE"; do
  # A digest override is already an immutable deployment input. This covers
  # both public digests and a previously published run-owned internal digest;
  # never attempt docker save/push against a registry-only reference.
  [[ "$image" == *@sha256:* ]] && continue
  name=$(basename "${image%%:*}")
  archive=$(mktemp "$STATE/.image-archive.XXXXXX.tar")
  docker save "$image" -o "$archive" >"$OUT/save-$name.log" 2>&1
  push_image="$REGISTRY/${image#*/}"
  skopeo copy --dest-tls-verify=true --dest-cert-dir "$REGISTRY_CERT_DIR" --authfile "$AUTHFILE" "docker-archive:$archive" "docker://$push_image" >"$OUT/push-$name.log" 2>&1
  rm -f "$archive"
  skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --authfile "$AUTHFILE" "docker://$push_image" | jq -r --arg image "$image" --arg pushed "$push_image" '{image:$image,pushed:$pushed,digest:.Digest}' >>"$OUT/image-digests.txt"
done
# Deploy registry images by their resolved manifest digests. Tags remain only
# as push inputs; this prevents node pulls from changing after qualification.
for image_var in CONTROLLER_IMAGE PRAXIS_IMAGE EXTPROC_IMAGE MAAS_API_IMAGE MAAS_CONTROLLER_IMAGE; do
  image_ref=${!image_var}
  if [[ "$image_ref" == *@sha256:* ]]; then
    printf '%s=%s\n' "$image_var" "$image_ref" >>"$OUT/image-digests.txt"
    continue
  fi
  image_base=${image_ref%:*}
  pushed_ref="$REGISTRY/${image_ref#*/}"
  image_digest=$(skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --authfile "$AUTHFILE" "docker://$pushed_ref" | jq -er '.Digest')
  printf '%s=%s@%s\n' "$image_var" "$image_base" "$image_digest" >>"$OUT/image-digests.txt"
  printf -v "$image_var" '%s@%s' "$image_base" "$image_digest"
done
rm -rf "$REGISTRY_CERT_DIR"

# Deploy only the source-matched MaaS controller lane. The repository-native
# deploy.sh also installs an OLM Kuadrant stack, which would compete with the
# pinned bootstrap operator on this component-level test cluster. Rendering
# MaaS's own production Kustomization preserves its controller/API behavior
# while leaving platform-operator ownership with bootstrap.sh.
MAAS_OVERLAY="$MAAS_CONTROLLER_REPO/.openshift-e2e-overlay.$$"
rm -rf "$MAAS_OVERLAY"
mkdir "$MAAS_OVERLAY"
cat >"$MAAS_OVERLAY/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: maas-system
resources:
- ../deployment/base/maas-controller/default
configMapGenerator:
- name: maas-parameters
  # Canonical MaaS main already generates this ConfigMap. Merge the immutable
  # run image inputs into that source-owned object instead of creating a
  # duplicate generator with the same resource identity.
  behavior: merge
  literals:
  - maas-api-image=$MAAS_API_IMAGE
  - maas-controller-image=$MAAS_CONTROLLER_IMAGE
  - namespace=maas-system
  - infrastructure-namespace=maas-system
  - monitoring-namespace=maas-system
patches:
- target:
    kind: Deployment
    name: maas-controller
  patch: |-
    - op: replace
      path: /spec/template/spec/containers/0/imagePullPolicy
      value: IfNotPresent
- target:
    kind: NetworkPolicy
    name: maas-controller-allow-monitoring
  patch: |-
    - op: add
      path: /spec/ingress/-
      value:
        from:
        - namespaceSelector: {}
        ports:
        - port: 9443
          protocol: TCP
EOF
MAAS_RENDERED="$STATE/.maas-rendered.$$"
kustomize build "$MAAS_OVERLAY" >"$MAAS_RENDERED"
# A prior run may have set this related-image variable to a literal value
# with `oc set env`, while canonical MaaS declares it as a ConfigMap-backed
# valueFrom. Remove only that generated override before applying the valid
# source manifest so Kubernetes does not merge incompatible EnvVar shapes.
if "${OC[@]}" get deployment maas-controller -n maas-system >/dev/null 2>&1; then
  "${OC[@]}" set env deployment/maas-controller -n maas-system \
    RELATED_IMAGE_ODH_MAAS_API_IMAGE- >"$OUT/normalize-maas-related-image-env.log" 2>&1
fi
"${OC[@]}" apply -f "$MAAS_RENDERED" >"$OUT/deploy-maas.log" 2>&1
attach_pull_secret_to_sa maas-system maas-controller
"${OC[@]}" set env deployment/maas-controller -n maas-system \
  GATEWAY_NAME="$OPENSHIFT_E2E_GATEWAY_NAME" \
  GATEWAY_NAMESPACE="$OPENSHIFT_E2E_GATEWAY_NAMESPACE" >>"$OUT/deploy-maas.log" 2>&1
"${OC[@]}" get deployment maas-controller -n maas-system -o json >"$OUT/maas-controller-after-gateway-env.json"
jq -e --arg gateway "$OPENSHIFT_E2E_GATEWAY_NAME" --arg namespace "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" '
  (.spec.template.spec.containers[0].env // []) as $env |
  ([ $env[] | select(.name == "GATEWAY_NAME") ] | length == 1 and .[0].value == $gateway and (.[0].valueFrom // null) == null) and
  ([ $env[] | select(.name == "GATEWAY_NAMESPACE") ] | length == 1 and .[0].value == $namespace and (.[0].valueFrom // null) == null)
' "$OUT/maas-controller-after-gateway-env.json" >/dev/null
"${OC[@]}" rollout restart deployment/maas-controller -n maas-system >>"$OUT/deploy-maas.log" 2>&1
KUBECONFIG="${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}" NAMESPACE=maas-system INFRA_NAMESPACE=maas-system "$MAAS_CONTROLLER_REPO/scripts/setup-database.sh" >>"$OUT/deploy-maas.log" 2>&1
rm -rf "$MAAS_OVERLAY" "$MAAS_RENDERED"
{
  "${OC[@]}" set image deployment/maas-controller manager="$MAAS_CONTROLLER_IMAGE" -n maas-system
  # The MaaS Tenant reconciler owns maas-api.  Use its documented related-image
  # override so reconciliation itself renders the source-matched immutable
  # image instead of restoring the upstream floating default.
  "${OC[@]}" set env deployment/maas-controller RELATED_IMAGE_ODH_MAAS_API_IMAGE="$MAAS_API_IMAGE" -n maas-system
  "${OC[@]}" patch deployment maas-controller -n maas-system --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
} >>"$OUT/deploy-maas.log" 2>&1
"${OC[@]}" rollout status deployment/maas-controller -n maas-system --timeout=300s >>"$OUT/deploy-maas.log" 2>&1

# Admission must be serving before the first AITenant is submitted. This gate
# checks the complete webhook contract, not merely Deployment existence.
if "${OC[@]}" get validatingwebhookconfiguration maas-validating-webhook-configuration -o json >/dev/null 2>&1; then
WEBHOOK_DEADLINE=$(( $(date +%s) + 180 ))
while :; do
  DEPLOYMENT_READY=$("${OC[@]}" get deployment maas-controller -n maas-system -o json 2>/dev/null | jq -r '.status.availableReplicas == 1 and .status.readyReplicas == 1' || true)
  ENDPOINT_READY=$("${OC[@]}" get endpoints maas-controller-webhook-service -n maas-system -o json 2>/dev/null | jq -r 'any(.subsets[]?.addresses[]?; .ip != null)' || true)
  WEBHOOK_READY=$("${OC[@]}" get validatingwebhookconfiguration maas-validating-webhook-configuration -o json 2>/dev/null | jq -r '[.webhooks[]? | select(.name=="vaitenant.kb.io") | select(.clientConfig.service.name=="maas-controller-webhook-service" and .clientConfig.service.namespace=="maas-system" and .clientConfig.service.port==443 and ((.clientConfig.caBundle // "")|length > 0))] | length == 1' || true)
  if [[ "$DEPLOYMENT_READY" == true && "$ENDPOINT_READY" == true && "$WEBHOOK_READY" == true ]]; then
    break
  fi
  (( $(date +%s) >= WEBHOOK_DEADLINE )) && { echo "MaaS webhook did not converge: deployment=$DEPLOYMENT_READY endpoints=$ENDPOINT_READY configuration=$WEBHOOK_READY" >&2; exit 1; }
  sleep 2
done
"${OC[@]}" get deployment,service,endpoints,validatingwebhookconfiguration -n maas-system -o json >"$OUT/webhook-state.json" 2>/dev/null || true
WEBHOOK_CERT=$(mktemp "$STATE/.maas-webhook-cert.XXXXXX")
"${OC[@]}" get secret maas-controller-webhook-cert -n maas-system -o jsonpath='{.data.tls\.crt}' | base64 -d >"$WEBHOOK_CERT"
openssl x509 -in "$WEBHOOK_CERT" -noout -subject -issuer -dates -ext subjectAltName >"$OUT/webhook-certificate.txt"
if ! openssl verify -CAfile <("${OC[@]}" get configmap openshift-service-ca.crt -n maas-system -o jsonpath='{.data.service-ca\.crt}') "$WEBHOOK_CERT" >"$OUT/webhook-certificate-verify.txt" 2>&1; then
  echo "MaaS webhook certificate failed service-ca verification" >&2
  exit 1
fi
rm -f "$WEBHOOK_CERT"
fi
if ! "${OC[@]}" apply --dry-run=server -f - >"$OUT/aitenant-admission-dry-run.txt" 2>&1 <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: AITenant
metadata:
  name: $AITENANT_NAME
  namespace: ai-tenants
  labels:
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
  annotations:
    maas.opendatahub.io/payload-processing-type: praxis
spec:
  gateway:
    name: $OPENSHIFT_E2E_GATEWAY_NAME
EOF
then
  echo "MaaS AITenant admission dry-run failed; see $OUT/aitenant-admission-dry-run.txt" >&2
  exit 1
fi

# MaaS owns AITenant bootstrap and reports the resolved namespace/status. This
# object is the only run-owned object placed in the platform AITenant namespace.
if [[ "$AITENANT_NAME" == models-as-a-service && ! -s "$STATE/aitenant-original.json" ]]; then
  # The shared MaaS AITenant is shared state: retain its metadata before the
  # run applies Praxis opt-in so cleanup can restore, never delete, it.
  if "${OC[@]}" get aitenant "$AITENANT_NAME" -n ai-tenants -o json >"$OUT/shared-aitenant-existing.json" 2>/dev/null; then
    jq '{metadata:{labels:(.metadata.labels // {}),annotations:(.metadata.annotations // {})},spec:.spec}' \
      "$OUT/shared-aitenant-existing.json" >"$STATE/aitenant-original.json"
  else
    jq -n '{metadata:{labels:{},annotations:{}},spec:{}}' >"$STATE/aitenant-original.json"
  fi
fi
"${OC[@]}" apply -f - <<EOF
apiVersion: maas.opendatahub.io/v1alpha1
kind: AITenant
metadata:
  name: $AITENANT_NAME
  namespace: ai-tenants
  labels:
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
  annotations:
    maas.opendatahub.io/payload-processing-type: praxis
spec:
  gateway:
    name: $OPENSHIFT_E2E_GATEWAY_NAME
EOF
AITENANT_OBSERVE_DEADLINE=$((SECONDS + 60))
while ! "${OC[@]}" get aitenant "$AITENANT_NAME" -n ai-tenants -o json >"$OUT/aitenant-after-create.json" 2>/dev/null; do
  (( SECONDS >= AITENANT_OBSERVE_DEADLINE )) && { echo "AITenant was not observable after successful admission/create" >&2; exit 1; }
  sleep 2
done
API_DEADLINE=$(( $(date +%s) + 300 ))
if [[ "$AITENANT_NAME" == models-as-a-service ]]; then
  API_DEPLOYMENT=maas-api
  while ! "${OC[@]}" get deployment "$API_DEPLOYMENT" -n maas-system -o json 2>/dev/null | jq -e --arg tenant "$AITENANT_NAME" '.metadata.labels["maas.opendatahub.io/tenant-name"] == $tenant and .status.availableReplicas == 1' >/dev/null; do
    (( $(date +%s) >= API_DEADLINE )) && { echo "default MaaS API deployment did not become Ready" >&2; exit 1; }
    sleep 2
  done
else
  while :; do
    API_DEPLOYMENT=$("${OC[@]}" get deployment -n maas-system -l "maas.opendatahub.io/tenant-name=$AITENANT_NAME" -o jsonpath='{.items[?(@.status.availableReplicas==1)].metadata.name}' 2>/dev/null | awk '{print $1}')
    [[ -n "$API_DEPLOYMENT" ]] && break
    (( $(date +%s) >= API_DEADLINE )) && { echo "MaaS API deployment was not created for the run tenant" >&2; exit 1; }
    sleep 2
  done
fi
api_service_account=$("${OC[@]}" get deployment "$API_DEPLOYMENT" -n maas-system -o jsonpath='{.spec.template.spec.serviceAccountName}')
[[ -n "$api_service_account" ]] || api_service_account=default
attach_pull_secret_to_sa maas-system "$api_service_account"
{
  "${OC[@]}" set image deployment/"$API_DEPLOYMENT" maas-api="$MAAS_API_IMAGE" -n maas-system
  "${OC[@]}" patch deployment "$API_DEPLOYMENT" -n maas-system --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]'
} >>"$OUT/deploy-maas.log" 2>&1
"${OC[@]}" rollout status deployment/"$API_DEPLOYMENT" -n maas-system --timeout=300s >>"$OUT/deploy-maas.log" 2>&1
"${OC[@]}" wait --for=condition=Ready "aitenant/$AITENANT_NAME" -n ai-tenants --timeout=10m >/dev/null
OPENSHIFT_E2E_TENANT_NAMESPACE=$("${OC[@]}" get aitenant "$AITENANT_NAME" -n ai-tenants -o jsonpath='{.status.tenantNamespace}')
[[ -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" ]] || { echo "MaaS did not report a resolved tenant namespace" >&2; exit 1; }
# The resolved shared tenant may differ from the provisional ai-tenants
# namespace. Create its pull Secret in the actual image-consuming namespace
# before attaching it to the tenant ServiceAccount.
RESOLVED_PULL_AUTHFILE=$(mktemp "$STATE/.resolved-pull-auth.XXXXXX")
rm -f "$RESOLVED_PULL_AUTHFILE"
"${OC[@]}" registry login --registry="$PULL_REGISTRY" --to="$RESOLVED_PULL_AUTHFILE" >"$OUT/registry-pull-login-resolved-tenant.log" 2>&1
"${OC[@]}" create secret generic "$PULL_SECRET" -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" \
  --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson="$RESOLVED_PULL_AUTHFILE" \
  --dry-run=client -o yaml | "${OC[@]}" apply -f - >"$OUT/registry-pull-secret-resolved-tenant.log" 2>&1
"${OC[@]}" label secret "$PULL_SECRET" -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" --overwrite \
  "external-model-praxis.opendatahub.io/run-id=$OPENSHIFT_E2E_RUN_ID" \
  app.kubernetes.io/managed-by=external-model-praxis-openshift-e2e >>"$OUT/registry-pull-secret-resolved-tenant.log" 2>&1
rm -f "$RESOLVED_PULL_AUTHFILE"
# Persist MaaS's resolved namespace for inspect/destroy and subsequent
# commands. The preflight value is only a provisional name.
run_env_tmp="$STATE/run.env.tmp.$$"
sed "s#^OPENSHIFT_E2E_TENANT_NAMESPACE=.*#OPENSHIFT_E2E_TENANT_NAMESPACE=$OPENSHIFT_E2E_TENANT_NAMESPACE#" "$STATE/run.env" >"$run_env_tmp"
mv "$run_env_tmp" "$STATE/run.env"

# The source-matched shared MaaS AITenant provides the canonical callback
# Service natively. Use it directly after proving its selector, endpoint, and
# service-ca certificate. The compatibility proxy is only for a non-primary
# tenant-qualified API and is never a production manifest.
if [[ "$AITENANT_NAME" == models-as-a-service ]]; then
  "${OC[@]}" get service maas-api -n maas-system -o json >"$OUT/native-callback-service.json"
  "${OC[@]}" get endpointslice -n maas-system -l kubernetes.io/service-name=maas-api -o json >"$OUT/native-callback-endpoints.json"
  jq -e '.spec.ports | any(.[]; .port == 8443 and .name == "https")' "$OUT/native-callback-service.json" >/dev/null
  jq -e '[.items[].endpoints[]? | select(.conditions.ready == true)] | length == 1' "$OUT/native-callback-endpoints.json" >/dev/null
  NATIVE_CERT=$(mktemp "$STATE/.native-maas-cert.XXXXXX")
  "${OC[@]}" get secret maas-api-serving-cert -n maas-system -o jsonpath='{.data.tls\.crt}' | base64 -d >"$NATIVE_CERT"
  openssl x509 -in "$NATIVE_CERT" -noout -subject -issuer -dates -ext subjectAltName >"$OUT/native-callback-certificate.txt"
  openssl verify -CAfile <("${OC[@]}" get configmap openshift-service-ca.crt -n maas-system -o jsonpath='{.data.service-ca\.crt}') "$NATIVE_CERT" >"$OUT/native-callback-certificate-verify.txt" 2>&1
  grep -q 'DNS:maas-api.maas-system.svc' "$OUT/native-callback-certificate.txt"
  grep -q 'DNS:maas-api.maas-system.svc.cluster.local' "$OUT/native-callback-certificate.txt"
  rm -f "$NATIVE_CERT"
else
  "$ROOT/test/openshift-env/compatibility.sh"
fi

# Authorino does not automatically trust OpenShift service-ca certificates.
# Create the trust bundle after the native MaaS Service exists, then attach it
# through the supported Authorino CR API before any AuthPolicy can authorize a
# request. The bundle contains only CA material; its value is never written
# to evidence.
AUTHORINO_TRUST_CONFIGMAP="xmp-service-ca-$OPENSHIFT_E2E_RUN_ID"
if [[ ! -s "$STATE/authorino-original-volumes.json" ]]; then
  "${OC[@]}" get authorino authorino -n kuadrant-system -o json |
    jq '{uid:.metadata.uid,volumes:(.spec.volumes // null)}' >"$STATE/authorino-original-volumes.json"
fi
"${OC[@]}" apply -f - >"$OUT/authorino-service-ca-configmap.log" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: $AUTHORINO_TRUST_CONFIGMAP
  namespace: kuadrant-system
  labels:
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
  annotations:
    service.beta.openshift.io/inject-cabundle: "true"
EOF
SERVICE_CA_DEADLINE=$(( $(date +%s) + 180 ))
while :; do
  SERVICE_CA_SIZE=$("${OC[@]}" get configmap "$AUTHORINO_TRUST_CONFIGMAP" -n kuadrant-system -o jsonpath='{.data.service-ca\.crt}' 2>/dev/null | wc -c | tr -d ' ' || true)
  [[ "$SERVICE_CA_SIZE" -gt 0 ]] && break
  if (( $(date +%s) >= SERVICE_CA_DEADLINE )); then
    "${OC[@]}" get configmap "$AUTHORINO_TRUST_CONFIGMAP" -n kuadrant-system -o json >"$OUT/authorino-service-ca-timeout.json" 2>&1 || true
    echo "OpenShift did not inject Authorino service-ca bundle; diagnostics: $OUT/authorino-service-ca-timeout.json" >&2
    exit 1
  fi
  sleep 2
done
SERVICE_CA_SHA=$("${OC[@]}" get configmap "$AUTHORINO_TRUST_CONFIGMAP" -n kuadrant-system -o jsonpath='{.data.service-ca\.crt}' | sha256sum | awk '{print $1}')
printf 'configmap=%s\nnamespace=kuadrant-system\nsha256=%s\nbytes=%s\n' "$AUTHORINO_TRUST_CONFIGMAP" "$SERVICE_CA_SHA" "$SERVICE_CA_SIZE" >"$OUT/authorino-service-ca.txt"
AUTHORINO_VOLUME_PATCH=$(jq -cn --arg cm "$AUTHORINO_TRUST_CONFIGMAP" '{spec:{volumes:{items:[{name:"service-ca",mountPath:"/etc/pki/ca-trust/extracted/pem",configMaps:[$cm],items:[{key:"service-ca.crt",path:"tls-ca-bundle.pem"}]}]}}}')
"${OC[@]}" patch authorino authorino -n kuadrant-system --type=merge -p "$AUTHORINO_VOLUME_PATCH" >"$OUT/authorino-service-ca-patch.log"
AUTHORINO_TRUST_DEADLINE=$(( $(date +%s) + 300 ))
while :; do
  AUTHORINO_POD=$("${OC[@]}" get pod -n kuadrant-system -l authorino-resource=authorino -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$AUTHORINO_POD" ]] && "${OC[@]}" get pod "$AUTHORINO_POD" -n kuadrant-system -o json 2>/dev/null | jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1' >/dev/null; then
    MOUNTED_SERVICE_CA_SHA=$("${OC[@]}" exec -n kuadrant-system "$AUTHORINO_POD" -- sha256sum /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem 2>/dev/null | awk '{print $1}' || true)
    [[ "$MOUNTED_SERVICE_CA_SHA" == "$SERVICE_CA_SHA" ]] && break
  fi
  if (( $(date +%s) >= AUTHORINO_TRUST_DEADLINE )); then
    "${OC[@]}" get authorino authorino -n kuadrant-system -o json >"$OUT/authorino-service-ca-timeout.json" 2>&1 || true
    echo "Authorino did not adopt the injected service-ca bundle; diagnostics: $OUT/authorino-service-ca-timeout.json" >&2
    exit 1
  fi
  sleep 3
done
printf 'authorino_pod=%s\ninjected_sha256=%s\nmounted_sha256=%s\n' "$AUTHORINO_POD" "$SERVICE_CA_SHA" "$MOUNTED_SERVICE_CA_SHA" >>"$OUT/authorino-service-ca.txt"
MAAS_CA_ENDPOINT_IP=$("${OC[@]}" get endpointslice -n maas-system -l kubernetes.io/service-name=maas-api -o jsonpath='{.items[0].endpoints[?(@.conditions.ready==true)].addresses[0]}' 2>/dev/null || true)
[[ -n "$MAAS_CA_ENDPOINT_IP" ]] || { echo "MaaS API has no ready endpoint for service-ca verification" >&2; exit 1; }
MAAS_CA_HOST=maas-api.maas-system.svc.cluster.local
TLS_PROBE="$OUT/authorino-to-maas-tls.txt"
: >"$TLS_PROBE"
TLS_DEADLINE=$(( $(date +%s) + 120 ))
while :; do
  TLS_ATTEMPT=$(mktemp "$STATE/.authorino-to-maas-tls.XXXXXX")
  set +e
  timeout 20s "${OC[@]}" exec -n kuadrant-system "$AUTHORINO_POD" -- sh -c "curl --silent --show-error --cacert /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem --resolve $MAAS_CA_HOST:8443:$MAAS_CA_ENDPOINT_IP --write-out 'status=%{http_code} ssl_verify_result=%{ssl_verify_result}\\n' --output /dev/null --max-time 10 https://$MAAS_CA_HOST:8443/health" >"$TLS_ATTEMPT" 2>&1
  TLS_RC=$?
  set -e
  cat "$TLS_ATTEMPT" >>"$TLS_PROBE"
  if [[ "$TLS_RC" -eq 0 ]]; then
    grep -q 'status=200 ssl_verify_result=0' "$TLS_ATTEMPT" || {
      rm -f "$TLS_ATTEMPT"
      echo "Authorino-to-MaaS TLS probe returned an unexpected HTTP response; diagnostics: $TLS_PROBE" >&2
      exit 1
    }
    rm -f "$TLS_ATTEMPT"
    break
  fi
  rm -f "$TLS_ATTEMPT"
  if (( $(date +%s) >= TLS_DEADLINE )); then
    echo "Authorino-to-MaaS TLS verification failed after transport convergence wait; diagnostics: $TLS_PROBE" >&2
    exit 1
  fi
  sleep 2
done

ROLE_NAME="xmp-controller-role-$OPENSHIFT_E2E_RUN_ID"
sed "0,/name: ai-gateway-controller-role/s//name: $ROLE_NAME/" "$ROOT/config/self/rbac/clusterrole.yaml" | sed "/^  name: $ROLE_NAME$/a\\  labels:\n    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID\n    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e" | "${OC[@]}" apply -f -
export ROLE_NAME CONTROLLER_IMAGE EXTPROC_IMAGE PRAXIS_IMAGE OPENSHIFT_E2E_GATEWAY_NAME OPENSHIFT_E2E_GATEWAY_NAMESPACE
"$ROOT/test/openshift-env/render-manifests.sh" "$RENDER_DIR" 20-controller.yaml.tmpl >"$OUT/render-manifests-controller.log"
apply_rendered 20-controller.yaml
attach_pull_secret_to_sa "$OPENSHIFT_E2E_CONTROLLER_NAMESPACE" ai-gateway-controller
export KATAN_IMAGE
"$ROOT/test/openshift-env/render-manifests.sh" "$RENDER_DIR" 30-provider-fixtures.yaml.tmpl >"$OUT/render-manifests-providers.log"
apply_rendered 30-provider-fixtures.yaml
# The provider Services request service-ca serving certificates.  Do not allow
# qualification to race the certificate injector or start Katan without TLS.
for provider in a b; do
  cert_deadline=$((SECONDS + 180))
  while ! "${OC[@]}" get secret "provider-$provider-tls" -n "$OPENSHIFT_E2E_BACKEND_NAMESPACE" >/dev/null 2>&1; do
    (( SECONDS < cert_deadline )) || { echo "service-ca certificate for provider-$provider did not appear" >&2; exit 1; }
    sleep 2
  done
  cert_keys=$("${OC[@]}" get secret "provider-$provider-tls" -n "$OPENSHIFT_E2E_BACKEND_NAMESPACE" -o json | jq -r '.data | keys | sort | join(",")')
  [[ "$cert_keys" == "tls.crt,tls.key" ]] || { echo "provider-$provider service-ca Secret is incomplete" >&2; exit 1; }
done
"${OC[@]}" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: provider-credentials
  namespace: $OPENSHIFT_E2E_TENANT_NAMESPACE
  labels:
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
stringData:
  # Matches LLM-Katan's documented test-only OpenAI validation key. This
  # fixture value is never copied into evidence or request arguments.
  api-key: llm-katan-openai-key
EOF
export OPENSHIFT_E2E_TENANT_NAMESPACE OPENSHIFT_E2E_BACKEND_NAMESPACE
export EXTERNAL_MODEL_NAMESPACE="$OPENSHIFT_E2E_TENANT_NAMESPACE"
export EXTERNAL_MODEL_RUN_ID="$OPENSHIFT_E2E_RUN_ID"
export EXTERNAL_MODEL_PROVIDER_A_ENDPOINT="provider-a.${OPENSHIFT_E2E_BACKEND_NAMESPACE}.svc.cluster.local"
export EXTERNAL_MODEL_PROVIDER_B_ENDPOINT="provider-b.${OPENSHIFT_E2E_BACKEND_NAMESPACE}.svc.cluster.local"
"$ROOT/test/openshift-env/render-manifests.sh" "$RENDER_DIR" providers.yaml.tmpl >"$OUT/render-manifests-shared-providers.log"
apply_rendered providers.yaml
"$ROOT/test/openshift-env/render-manifests.sh" "$RENDER_DIR" 40-model-fixtures.yaml.tmpl >"$OUT/render-manifests-models.log"
apply_rendered 40-model-fixtures.yaml
export OPENSHIFT_E2E_USER
"$ROOT/test/openshift-env/render-manifests.sh" "$RENDER_DIR" 50-maas-fixtures.yaml.tmpl >"$OUT/render-manifests-maas.log"
apply_rendered 50-maas-fixtures.yaml

# MaaS creates the gateway AuthPolicy from its fixture.  Do not finish
# provisioning until Kuadrant has both accepted and enforced that generated
# policy; otherwise the first unauthenticated request can be routed without
# authentication while the control plane is still converging.
AUTH_POLICY_EVIDENCE="$OUT/maas-gateway-auth-ready.json"
AUTH_POLICY_DEADLINE=$((SECONDS + 300))
while :; do
  AUTH_POLICY_STATUS=$("${OC[@]}" get authpolicy maas-gateway-auth -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" -o json 2>/dev/null || true)
  if [[ -n "$AUTH_POLICY_STATUS" ]] && jq -e '[.status.conditions[]? | select((.type == "Accepted" or .type == "Enforced") and .status == "True")] | length == 2' <<<"$AUTH_POLICY_STATUS" >/dev/null; then
    printf '%s\n' "$AUTH_POLICY_STATUS" >"$AUTH_POLICY_EVIDENCE"
    break
  fi
  if (( SECONDS >= AUTH_POLICY_DEADLINE )); then
    printf '%s\n' "${AUTH_POLICY_STATUS:-{}}" >"$AUTH_POLICY_EVIDENCE"
    echo "generated MaaS AuthPolicy did not become Accepted and Enforced; diagnostics: $AUTH_POLICY_EVIDENCE" >&2
    exit 1
  fi
  sleep 3
done
for _ in $(seq 1 60); do
  praxis_sa=$("${OC[@]}" get serviceaccount -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -l app.kubernetes.io/managed-by=ai-gateway-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  [[ -n "$praxis_sa" ]] && break
  sleep 2
done
[[ -n "${praxis_sa:-}" ]] || { echo "controller did not create a tenant Praxis ServiceAccount" >&2; exit 1; }
attach_pull_secret_to_sa "$OPENSHIFT_E2E_TENANT_NAMESPACE" "$praxis_sa"
"${OC[@]}" apply -f - >"$OUT/image-puller-resolved-tenant.log" <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: image-puller-resolved-tenant-$OPENSHIFT_E2E_RUN_ID
  namespace: $OPENSHIFT_E2E_BACKEND_NAMESPACE
  labels:
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:image-puller
subjects:
- kind: ServiceAccount
  name: $praxis_sa
  namespace: $OPENSHIFT_E2E_TENANT_NAMESPACE
EOF
# The Praxis Deployment may have been created before the resolved-tenant
# image-puller binding existed.  Restart it through its normal Deployment
# lifecycle after the exact ServiceAccount authorization is in place; this is
# required for an idempotent retry of an ImagePullBackOff, before qualification
# records workload identity.
if "${OC[@]}" get deployment -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -l app=praxis -o name 2>/dev/null | grep -q .; then
  # Katan's service-ca certificate is valid but is not part of Praxis's base
  # image trust store. Build a combined run-owned bundle rather than replacing
  # the image's public CA bundle: external providers such as api.openai.com
  # must continue to use normal public certificate verification. This is
  # fixture plumbing only; it does not change controller-rendered TLS or
  # disable certificate verification.
  PROVIDER_CA_CONFIGMAP="xmp-provider-ca-$OPENSHIFT_E2E_RUN_ID"
  PROVIDER_CA_BUNDLE=$(mktemp "$STATE/.provider-ca-bundle.XXXXXX")
  PROVIDER_CA_SERVICE=$(mktemp "$STATE/.provider-service-ca.XXXXXX")
  praxis_pod=""
  PROVIDER_CA_COLLECTION_LOG="$OUT/provider-ca-collection.log"
  : >"$PROVIDER_CA_COLLECTION_LOG"
  provider_ca_ready=false
  for _ in $(seq 1 120); do
    praxis_pod=$("${OC[@]}" get pod -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -l app=praxis -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$praxis_pod" ]] && "${OC[@]}" exec "$praxis_pod" -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -- \
      sh -c 'cat /etc/ssl/certs/ca-certificates.crt' >"$PROVIDER_CA_BUNDLE" 2>>"$PROVIDER_CA_COLLECTION_LOG" && [[ -s "$PROVIDER_CA_BUNDLE" ]]; then
      provider_ca_ready=true
      break
    fi
    sleep 2
  done
  [[ "$provider_ca_ready" == true ]] || { echo "Praxis container was not ready to collect the base CA bundle; diagnostics: $PROVIDER_CA_COLLECTION_LOG" >&2; exit 1; }
  "${OC[@]}" get configmap openshift-service-ca.crt -n "$OPENSHIFT_E2E_BACKEND_NAMESPACE" \
    -o jsonpath='{.data.service-ca\.crt}' >"$PROVIDER_CA_SERVICE"
  cat "$PROVIDER_CA_SERVICE" >>"$PROVIDER_CA_BUNDLE"
  "${OC[@]}" create configmap "$PROVIDER_CA_CONFIGMAP" -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" \
    --from-file=ca-bundle.crt="$PROVIDER_CA_BUNDLE" \
    --dry-run=client -o yaml | "${OC[@]}" apply -f - >"$OUT/provider-ca-configmap.log"
  PROVIDER_CA_PATCH=$(jq -cn --arg cm "$PROVIDER_CA_CONFIGMAP" '{spec:{template:{spec:{containers:[{name:"praxis",env:[{name:"SSL_CERT_FILE",value:"/etc/praxis/provider-ca/ca-bundle.crt"}],volumeMounts:[{name:"provider-ca",mountPath:"/etc/praxis/provider-ca",readOnly:true}]}],volumes:[{name:"provider-ca",configMap:{name:$cm}}]}}}}')
  "${OC[@]}" patch deployment praxis -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" --type=strategic -p "$PROVIDER_CA_PATCH" >"$OUT/provider-ca-patch.log"
  "${OC[@]}" rollout restart deployment -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -l app=praxis >"$OUT/praxis-rollout-retry.log"
  "${OC[@]}" rollout status deployment -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -l app=praxis --timeout=300s >>"$OUT/praxis-rollout-retry.log"
fi
"${OC[@]}" get deployment,service,externalmodel,externalprovider -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" -o json >"$OUT/tenant-after-fixtures.json"

# Keep one run-owned in-cluster client for functional qualification.  Only the
# public Gateway certificate is copied; no private key or credential is
# mounted.  Requests and temporary API keys are supplied over stdin by the
# qualification script, never as pod arguments or evidence.
CLIENT_CA_CONFIGMAP="xmp-gateway-ca-$OPENSHIFT_E2E_RUN_ID"
CLIENT_CA_FILE=$(mktemp)
"${OC[@]}" get secret "$OPENSHIFT_E2E_GATEWAY_TLS_SECRET" -n "$OPENSHIFT_E2E_GATEWAY_NAMESPACE" -o jsonpath='{.data.tls\.crt}' | base64 -d >"$CLIENT_CA_FILE"
"${OC[@]}" get configmap openshift-service-ca.crt -n "$OPENSHIFT_E2E_BACKEND_NAMESPACE" -o jsonpath='{.data.service-ca\.crt}' >>"$CLIENT_CA_FILE"
"${OC[@]}" create configmap "$CLIENT_CA_CONFIGMAP" -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" --from-file=ca.crt="$CLIENT_CA_FILE" \
    --dry-run=client -o yaml | "${OC[@]}" apply -f - >"$OUT/client-ca-configmap.log"
export CLIENT_CA_CONFIGMAP
export EXTERNAL_MODEL_CLIENT_NAME="xmp-client-$OPENSHIFT_E2E_RUN_ID"
export EXTERNAL_MODEL_CLIENT_NAMESPACE="$OPENSHIFT_E2E_TENANT_NAMESPACE"
export EXTERNAL_MODEL_CLIENT_IMAGE='curlimages/curl:8.10.1@sha256:d9b4541e214bcd85196d6e92e2753ac6d0ea699f0af5741f8c6cccbfcf00ef4b'
export EXTERNAL_MODEL_CLIENT_VOLUME_MOUNTS='[{name: gateway-ca, mountPath: /etc/xmp/ca, readOnly: true}]'
export EXTERNAL_MODEL_CLIENT_VOLUMES="[{name: gateway-ca, configMap: {name: $CLIENT_CA_CONFIGMAP}}]"
"$ROOT/test/openshift-env/render-manifests.sh" "$RENDER_DIR" client.yaml.tmpl >"$OUT/render-manifests-client.log"
apply_rendered client.yaml
"${OC[@]}" wait --for=condition=Ready pod/"$EXTERNAL_MODEL_CLIENT_NAME" -n "$OPENSHIFT_E2E_TENANT_NAMESPACE" --timeout=120s
printf '%s\n' "$OUT"
