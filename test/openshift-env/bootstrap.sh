#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${OPENSHIFT_E2E_STATE:-"$ROOT/.openshift-state"}
# shellcheck disable=SC1091
source "$STATE/run.env"
OC=(timeout --foreground "${OPENSHIFT_E2E_OC_POINT_TIMEOUT:-45s}" oc --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}")
OC_LONG=(timeout --foreground "${OPENSHIFT_E2E_OC_LONG_TIMEOUT:-300s}" oc --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}")
OUT="$OPENSHIFT_E2E_EVIDENCE_ROOT/bootstrap"
mkdir -p "$OUT"

need() { command -v "$1" >/dev/null || { echo "$1 is required" >&2; exit 1; }; }
need oc; need helm; need kustomize; need yq; need curl; need tar
[[ -n "${KUADRANT_OPERATOR_REPO:-}" && -d "$KUADRANT_OPERATOR_REPO" ]] || { echo 'KUADRANT_OPERATOR_REPO must point to the pinned Kuadrant checkout' >&2; exit 1; }

# MaaS v0.1.x requires the Kuadrant v1.4.2 bundle, which provides the
# Authorino v0.23.1 operator.  Do not qualify against an arbitrary checkout or
# a moving catalog: the catalog digest is the executable dependency and the
# Git tag is its source provenance.  The v1.4.2 bundle is intentionally
# installed without its Sail Istio resource below because this harness owns
# the single pinned Istio control plane.
KUADRANT_OPERATOR_VERSION=${KUADRANT_OPERATOR_VERSION:-v1.4.2}
KUADRANT_CATALOG_IMAGE=${KUADRANT_CATALOG_IMAGE:-quay.io/kuadrant/kuadrant-operator-catalog@sha256:8734980493c3105716fdd2d6b7ddf21f27079cc3ba1c58621038abef2ce4dc8e}
AUTHORINO_RUNTIME_VERSION=${AUTHORINO_RUNTIME_VERSION:-0.24.0}
AUTHORINO_RUNTIME_DIGEST=${AUTHORINO_RUNTIME_DIGEST:-sha256:96b1b9737cf5f546d132e45bd04513096c76a5655e151741306e886e598fc999}
[[ "$KUADRANT_CATALOG_IMAGE" == *@sha256:* ]] || { echo 'KUADRANT_CATALOG_IMAGE must be digest-pinned' >&2; exit 1; }
[[ "$AUTHORINO_RUNTIME_DIGEST" == sha256:* ]] || { echo 'AUTHORINO_RUNTIME_DIGEST must be digest-pinned' >&2; exit 1; }
KUADRANT_SOURCE_TAG=$(git -C "$KUADRANT_OPERATOR_REPO" describe --tags --exact-match HEAD 2>/dev/null || true)
[[ "$KUADRANT_SOURCE_TAG" == "$KUADRANT_OPERATOR_VERSION" ]] || {
  echo "Kuadrant checkout must be exactly $KUADRANT_OPERATOR_VERSION; observed ${KUADRANT_SOURCE_TAG:-unTagged-HEAD}" >&2
  exit 1
}

pin_kuadrant_catalog_image() {
  awk -v image="$KUADRANT_CATALOG_IMAGE" '
    $0 == "  image: quay.io/kuadrant/kuadrant-operator-catalog:latest" ||
    $0 == "  image: quay.io/kuadrant/kuadrant-operator-catalog:v1.4.2" { print "  image: " image; count++; next }
    { print }
    END { if (count != 1) exit 1 }
  '
}

normalize_kuadrant_olm() {
  # The v1.4.2 catalog publishes Kuadrant on stable.  Its source bundle also
  # contains a Sail Subscription; omit that dependency because this harness
  # already installs and validates one Istio control plane itself.
  yq eval-all 'select(.kind != "Subscription" or .metadata.name != "sailoperator") | with(select(.kind == "Subscription" and .metadata.name == "kuadrant"); .spec.channel = "stable")' -
}

# OpenShift's Ingress Operator owns Gateway API CRDs. Kuadrant's install
# bundle carries copies of them, so remove only those CRD documents before
# applying the otherwise unchanged operator manifests.
without_managed_gateway_crds() {
  # Select by parsed metadata.name, not by text matching: CRD schemas contain
  # many unrelated gateway strings in descriptions and examples.
  yq eval-all 'select(.kind != "CustomResourceDefinition" or ((.metadata.name // "") | test("^[a-z0-9-]+\\.gateway\\.networking\\.k8s\\.io$") | not))' -
}

if ! "${OC[@]}" get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1; then
  "${OC_LONG[@]}" apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/standard-install.yaml >"$OUT/gateway-api-install.log" 2>&1
fi
"${OC[@]}" get crd gatewayclasses.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io -o name >"$OUT/gateway-api-crds.txt"

cert_manager_is_healthy() {
  local deployment
  "${OC[@]}" get namespace cert-manager >/dev/null 2>&1 || return 1
  for deployment in cert-manager cert-manager-cainjector cert-manager-webhook; do
    "${OC[@]}" wait "deployment/$deployment" -n cert-manager --for=condition=Available --timeout=30s >/dev/null 2>&1 || return 1
  done
  "${OC[@]}" get crd certificates.cert-manager.io certificaterequests.cert-manager.io issuers.cert-manager.io clusterissuers.cert-manager.io >/dev/null 2>&1
}

if cert_manager_is_healthy; then
  printf '%s\n' 'healthy ODH-managed cert-manager reused as shared infrastructure; Helm ownership was not modified' >"$OUT/cert-manager-shared.txt"
else
  if "${OC[@]}" get namespace cert-manager >/dev/null 2>&1 ||
     "${OC[@]}" get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo 'cert-manager is present but not healthy; refusing to adopt or reinstall shared resources' >&2
    exit 1
  fi
  helm upgrade --install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.15.3 --set crds.enabled=true --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}" --wait --timeout 300s >"$OUT/cert-manager.log" 2>&1
fi

ISTIO_VERSION=${ISTIO_VERSION:-1.26.2}
ISTIO_CACHE="$STATE/cache/istio-$ISTIO_VERSION"
ISTIO_READY_MARKER="$STATE/istio-$ISTIO_VERSION.ready"
mkdir -p "$STATE/cache"
if [[ ! -x "$ISTIO_CACHE/bin/istioctl" ]]; then
  archive="$STATE/cache/istio-$ISTIO_VERSION-linux-amd64.tar.gz"
  curl -fsSL --retry 2 "https://github.com/istio/istio/releases/download/$ISTIO_VERSION/istio-$ISTIO_VERSION-linux-amd64.tar.gz" -o "$archive"
  tar -xzf "$archive" -C "$STATE/cache"
  sha256sum "$archive" >"$STATE/cache/istio-$ISTIO_VERSION.sha256"
fi
# The qualification uses one Istio control plane. Reuse a healthy ODH-managed
# control plane when present; never adopt, relabel, or install beside it.
EXISTING_ISTIOD=$("${OC[@]}" get deployment -A -l app=istiod -o json 2>/dev/null | jq '[.items[] | {namespace:.metadata.namespace,name:.metadata.name,runId:(.metadata.labels["external-model-praxis.opendatahub.io/run-id"] // "")}]')
ISTIO_SERVICE_NAME=istiod
ISTIO_ROOT_CERT_SECRET=istio-ca-secret
ISTIO_GATEWAY_CLASS=istio
if [[ "$(jq 'length' <<<"$EXISTING_ISTIOD")" -ne 0 ]]; then
  printf '%s\n' "$EXISTING_ISTIOD" >"$OUT/preexisting-istiod.json"
  if [[ -n "${OPENSHIFT_E2E_REPAIR_ISTIO_RUN_ID:-}" ]]; then
    REPAIR_EVIDENCE="$STATE/evidence/$OPENSHIFT_E2E_REPAIR_ISTIO_RUN_ID/bootstrap"
    REPAIR_DEPLOYMENT=$("${OC[@]}" get deployment istiod -n istio-system -o json 2>/dev/null || true)
    jq -e --arg image "docker.io/istio/pilot:$ISTIO_VERSION" \
      '.metadata.namespace == "istio-system" and .metadata.name == "istiod" and
       (.spec.template.spec.containers[0].image == $image) and
       (.metadata.ownerReferences // [] | length == 0)' <<<"$REPAIR_DEPLOYMENT" >/dev/null || {
      echo "refusing Istio recovery: live control plane shape is not the expected harness installation" >&2
      exit 1
    }
    [[ -f "$REPAIR_EVIDENCE/istio.log" || -f "$REPAIR_EVIDENCE/istio-scc.log" ]] || {
      echo "refusing Istio recovery: prior run evidence is unavailable: $REPAIR_EVIDENCE" >&2
      exit 1
    }
    printf '%s\n' 'evidence-gated recovery of prior harness Istio installation' >"$OUT/istio-recovery.txt"
    "$ISTIO_CACHE/bin/istioctl" uninstall --purge -y --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}" >"$OUT/istio-recovery-uninstall.log" 2>&1
    "${OC_LONG[@]}" delete namespace istio-system --ignore-not-found --wait=true --timeout=5m >>"$OUT/istio-recovery-uninstall.log" 2>&1
    EXISTING_ISTIOD='[]'
  fi
  if [[ -z "${OPENSHIFT_E2E_REPAIR_ISTIO_RUN_ID:-}" ]]; then
    if [[ "$(jq -r 'length == 1 and .[0].namespace == "istio-system" and .[0].name == "istiod"' <<<"$EXISTING_ISTIOD")" == true ]]; then
      printf '%s\n' 'reusing the single shared istio-system/istiod control plane' >"$OUT/istio-reused.txt"
    else
      ISTIO_NS=$(jq -r '.[0].namespace' <<<"$EXISTING_ISTIOD")
      ISTIO_DEPLOYMENT=$(jq -r '.[0].name' <<<"$EXISTING_ISTIOD")
      ISTIO_REVISION=$("${OC[@]}" get deployment "$ISTIO_DEPLOYMENT" -n "$ISTIO_NS" -o jsonpath='{.metadata.labels.istio\.io/rev}' 2>/dev/null || true)
      [[ -n "$ISTIO_REVISION" ]] || { echo "shared Istio deployment has no revision label; diagnostics: $OUT/preexisting-istiod.json" >&2; exit 1; }
      ISTIO_SERVICE_NAME=$("${OC[@]}" get service -n "$ISTIO_NS" -l "app=istiod,istio.io/rev=$ISTIO_REVISION" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
      [[ -n "$ISTIO_SERVICE_NAME" ]] || { echo "shared Istio Service is missing; diagnostics: $OUT/preexisting-istiod.json" >&2; exit 1; }
      "${OC[@]}" get secret "$ISTIO_ROOT_CERT_SECRET" -n "$ISTIO_NS" >/dev/null 2>&1 || { echo "shared Istio root CA Secret is missing; diagnostics: $OUT/preexisting-istiod.json" >&2; exit 1; }
      for gateway_class in data-science-gateway-class openshift-default; do
        if "${OC[@]}" get gatewayclass "$gateway_class" -o json 2>/dev/null | jq -e '[.status.conditions[]? | select(.type == "Accepted" and .status == "True")] | length == 1' >/dev/null; then
          ISTIO_GATEWAY_CLASS=$gateway_class
          break
        fi
      done
      [[ "$ISTIO_GATEWAY_CLASS" != istio ]] || { echo "shared Istio has no accepted ODH GatewayClass; diagnostics: $OUT/preexisting-istiod.json" >&2; exit 1; }
      printf 'reusing shared ODH Istio control plane: %s/%s via GatewayClass %s\n' "$ISTIO_NS" "$ISTIO_SERVICE_NAME" "$ISTIO_GATEWAY_CLASS" >"$OUT/istio-reused.txt"
    fi
  fi
  if [[ -n "${OPENSHIFT_E2E_REPAIR_ISTIO_RUN_ID:-}" ]]; then
    ISTIO_ALREADY_INSTALLED=false
  else
    ISTIO_ALREADY_INSTALLED=true
  fi
else
  ISTIO_ALREADY_INSTALLED=false
fi
if [[ "$ISTIO_ALREADY_INSTALLED" == false ]]; then
"${OC_LONG[@]}" apply -f - >"$OUT/istio-scc.log" <<EOF
apiVersion: security.openshift.io/v1
kind: SecurityContextConstraints
metadata:
  name: xmp-istio-$OPENSHIFT_E2E_RUN_ID
  labels:
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
allowHostDirVolumePlugin: false
allowHostNetwork: false
allowPrivilegedContainer: false
allowPrivilegeEscalation: false
readOnlyRootFilesystem: false
runAsUser: {type: RunAsAny}
fsGroup: {type: RunAsAny}
seLinuxContext: {type: MustRunAs}
supplementalGroups: {type: RunAsAny}
volumes: [configMap, downwardAPI, emptyDir, projected, secret, persistentVolumeClaim]
users:
- system:serviceaccount:istio-system:istiod
- system:serviceaccount:istio-system:istio-ingressgateway-service-account
EOF
"$ISTIO_CACHE/bin/istioctl" install --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}" --set profile=minimal --set components.ingressGateways[0].name=istio-ingressgateway --set components.ingressGateways[0].enabled=true --set values.gateways.istio-ingressgateway.autoscaleEnabled=false --set values.gateways.istio-ingressgateway.replicaCount=1 -y >"$OUT/istio.log" 2>&1
"${OC_LONG[@]}" rollout status deployment/istio-ingressgateway -n istio-system --timeout=300s
fi

# Never repair an unowned Istio webhook in place. A previous installation can
# leave a second control plane or a webhook signed by the other control plane.
# Both cases must fail before MaaS or an AITenant is touched.
ISTIO_CHAIN="$OUT/istio-admission-chain"
mkdir -p "$ISTIO_CHAIN"
"${OC[@]}" get mutatingwebhookconfiguration,validatingwebhookconfiguration -o json >"$ISTIO_CHAIN/webhooks.json"
"${OC[@]}" get deployment,pod,service,endpoints -A -l app=istiod -o json >"$ISTIO_CHAIN/istiod-resources.json" 2>/dev/null || true
"${OC[@]}" get secret -A -l istio.io/ca-root -o json | jq 'del(.items[]?.data)' >"$ISTIO_CHAIN/ca-secret-metadata.json" 2>/dev/null || true

ISTIO_DEPLOYMENTS=$("${OC[@]}" get deployment -A -l app=istiod -o json | jq '[.items[] | {namespace:.metadata.namespace,name:.metadata.name}]')
printf '%s\n' "$ISTIO_DEPLOYMENTS" >"$ISTIO_CHAIN/istiod-deployments.json"
ISTIO_DEPLOYMENT_COUNT=$(jq 'length' <<<"$ISTIO_DEPLOYMENTS")
if [[ "$ISTIO_DEPLOYMENT_COUNT" -ne 1 ]]; then
  echo "expected exactly one active Istio control plane; found $ISTIO_DEPLOYMENT_COUNT" >&2
  echo "diagnostics: $ISTIO_CHAIN" >&2
  exit 1
fi

ISTIO_NS=$(jq -r '.[0].namespace' <<<"$ISTIO_DEPLOYMENTS")
ISTIO_SERVICE=$("${OC[@]}" get service "$ISTIO_SERVICE_NAME" -n "$ISTIO_NS" -o json 2>/dev/null || true)
printf '%s\n' "$ISTIO_SERVICE" >"$ISTIO_CHAIN/istiod-service.json"
[[ -n "$ISTIO_SERVICE" ]] || { echo "Istio Service $ISTIO_SERVICE_NAME is missing in $ISTIO_NS; diagnostics: $ISTIO_CHAIN" >&2; exit 1; }
"${OC[@]}" get endpoints "$ISTIO_SERVICE_NAME" -n "$ISTIO_NS" -o json >"$ISTIO_CHAIN/istiod-endpoints.json"
if ! jq -e 'any(.subsets[]?.addresses[]?; .ip != null)' "$ISTIO_CHAIN/istiod-endpoints.json" >/dev/null; then
  echo "Istio Service has no ready endpoints; diagnostics: $ISTIO_CHAIN" >&2
  exit 1
fi

ROOT_CERT=$(mktemp "$STATE/.istio-root-cert.XXXXXX")
trap 'rm -f "$ROOT_CERT"' EXIT
if ! "${OC[@]}" get secret "$ISTIO_ROOT_CERT_SECRET" -n "$ISTIO_NS" -o json | jq -r '.data["root-cert.pem"]' | base64 -d >"$ROOT_CERT" || [[ ! -s "$ROOT_CERT" ]]; then
  echo "Istio root certificate is unavailable in $ISTIO_NS; diagnostics: $ISTIO_CHAIN" >&2
  exit 1
fi
ROOT_SHA=$(sha256sum "$ROOT_CERT" | awk '{print $1}')
printf 'namespace=%s\nroot_cert_sha256=%s\n' "$ISTIO_NS" "$ROOT_SHA" >"$ISTIO_CHAIN/root-cert.txt"
# Verify the certificate actually served by the Istio Service, using the
# installed root certificate and the same SNI/name used by the webhook
# Service. Port-forwarding keeps this check independent of the control-plane
# image contents; only the verification result is written to evidence.
ISTIO_SERVER_NAME="$ISTIO_SERVICE_NAME.$ISTIO_NS.svc"
command -v openssl >/dev/null || { echo 'openssl is required for Istio certificate verification' >&2; exit 1; }
ISTIO_FORWARD_LOG=$(mktemp "$STATE/.istio-port-forward.XXXXXX")
"${OC[@]}" port-forward -n "$ISTIO_NS" "service/$ISTIO_SERVICE_NAME" 0:443 >"$ISTIO_FORWARD_LOG" 2>&1 &
ISTIO_FORWARD_PID=$!
ISTIO_LOCAL_PORT=""
for _ in {1..30}; do
  ISTIO_LOCAL_PORT=$(sed -nE 's/.*Forwarding from 127\.0\.0\.1:([0-9]+) -> [0-9]+.*/\1/p' "$ISTIO_FORWARD_LOG" | head -1)
  [[ -n "$ISTIO_LOCAL_PORT" ]] && break
  sleep 1
done
if [[ -z "$ISTIO_LOCAL_PORT" ]]; then
  printf '%s\n' 'port-forward did not become ready' >"$ISTIO_CHAIN/live-serving-certificate.txt"
  printf '%s\n' "$(sed -n '1,20p' "$ISTIO_FORWARD_LOG")" >>"$ISTIO_CHAIN/live-serving-certificate.txt"
  kill "$ISTIO_FORWARD_PID" 2>/dev/null || true
  wait "$ISTIO_FORWARD_PID" 2>/dev/null || true
  rm -f "$ISTIO_FORWARD_LOG"
  exit 1
fi
set +e
LIVE_CERT_RESULT=$(timeout 30s openssl s_client -connect "127.0.0.1:$ISTIO_LOCAL_PORT" -servername "$ISTIO_SERVER_NAME" -CAfile "$ROOT_CERT" -verify_return_error -brief </dev/null 2>&1)
OPENSSL_RC=$?
set -e
kill "$ISTIO_FORWARD_PID" 2>/dev/null || true
wait "$ISTIO_FORWARD_PID" 2>/dev/null || true
rm -f "$ISTIO_FORWARD_LOG"
printf '%s\n' "$LIVE_CERT_RESULT" >"$ISTIO_CHAIN/live-serving-certificate.txt"
printf 'openssl_exit=%s\n' "$OPENSSL_RC" >>"$ISTIO_CHAIN/live-serving-certificate.txt"
if [[ "$OPENSSL_RC" -ne 0 ]] || ! grep -q 'Verification: OK' "$ISTIO_CHAIN/live-serving-certificate.txt"; then
  echo "Istio live serving certificate verification failed; diagnostics: $ISTIO_CHAIN" >&2
  exit 1
fi

VALIDATION_WEBHOOK_COUNT=$(jq '[.items[] | .webhooks[]? | select((.name // "") | test("validation\\.istio\\.io"))] | length' "$ISTIO_CHAIN/webhooks.json")
if [[ "$VALIDATION_WEBHOOK_COUNT" -eq 0 ]]; then
  echo "no Istio validation webhook was found; diagnostics: $ISTIO_CHAIN" >&2
  exit 1
fi
if ! jq -r '.items[] | . as $c | .webhooks[]? | select((.name // "") | test("validation\\.istio\\.io")) | [$c.metadata.name,.name,(.clientConfig.service.name // ""),(.clientConfig.service.namespace // ""),(.clientConfig.service.path // ""),((.clientConfig.service.port // "")|tostring),(.clientConfig.caBundle // "")] | @tsv' "$ISTIO_CHAIN/webhooks.json" |
  while IFS=$'\t' read -r config name service namespace path port bundle; do
    [[ "$namespace" == "$ISTIO_NS" && "$service" == "$ISTIO_SERVICE_NAME" && "$path" == "/validate" && "$port" == 443 && -n "$bundle" ]] || { echo "invalid Istio validation webhook target: $config/$name" >&2; exit 1; }
    bundle_sha=$(printf '%s' "$bundle" | base64 -d | sha256sum | awk '{print $1}')
    printf '%s/%s service=%s/%s path=%s port=%s ca_sha=%s\n' "$config" "$name" "$namespace" "$service" "$path" "$port" "$bundle_sha"
    [[ "$bundle_sha" == "$ROOT_SHA" ]] || { echo "Istio webhook CA does not match $ISTIO_NS root: $config/$name" >&2; exit 1; }
  done >"$ISTIO_CHAIN/validation-webhooks.txt"; then
  echo "Istio validation webhook trust or target is not converged; diagnostics: $ISTIO_CHAIN" >&2
  exit 1
fi

if ! "${OC_LONG[@]}" apply --dry-run=server -f - >"$ISTIO_CHAIN/admission-dry-run.txt" 2>&1 <<EOF
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: xmp-istio-admission-probe-$OPENSHIFT_E2E_RUN_ID
  namespace: $ISTIO_NS
spec:
  hosts: [admission-probe.invalid]
  http:
  - route:
    - destination: {host: admission-probe.invalid}
EOF
then
  echo "Istio admission dry-run failed; diagnostics: $ISTIO_CHAIN" >&2
  exit 1
fi

# The marker is local, non-secret provenance for this harness state. Shared
# Istio resources are intentionally not relabeled. A later idempotent
# bootstrap may reuse this exact, already-validated control plane.
printf 'version=%s\nnamespace=%s\nservice=%s\ngateway_class=%s\n' "$ISTIO_VERSION" "$ISTIO_NS" "$ISTIO_SERVICE_NAME" "$ISTIO_GATEWAY_CLASS" >"$ISTIO_READY_MARKER.tmp"
mv "$ISTIO_READY_MARKER.tmp" "$ISTIO_READY_MARKER"
printf '%s\n' "$ISTIO_GATEWAY_CLASS" >"$STATE/istio-gateway-class.txt.tmp"
mv "$STATE/istio-gateway-class.txt.tmp" "$STATE/istio-gateway-class.txt"

# Istio namespace, control-plane objects, and admission webhooks are shared
# cluster infrastructure, not run-owned resources.  Record their identity and
# leave their ownership labels untouched; only the run-owned SCC is cleaned up.
printf 'namespace=%s\ncontrol_plane=istiod\nownership=shared-platform-infrastructure\n' "$ISTIO_NS" >"$ISTIO_CHAIN/ownership.txt"

KUADRANT_SHARED=false
KUADRANT_NAME=kuadrant
if "${OC[@]}" get deployment kuadrant-operator-controller-manager -n kuadrant-system >/dev/null 2>&1; then
  KUADRANT_NAME=$("${OC[@]}" get kuadrant -n kuadrant-system -o json 2>/dev/null | jq -r '[.items[] | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1) | .metadata.name] | if length == 1 then .[0] else "" end')
  KUADRANT_OPERATOR_READY=$("${OC[@]}" get deployment kuadrant-operator-controller-manager -n kuadrant-system -o json | jq -e '.status.availableReplicas >= 1 and .status.readyReplicas >= 1' >/dev/null; echo $?)
  AUTHORINO_OPERATOR_READY=$("${OC[@]}" get deployment authorino-operator -n kuadrant-system -o json 2>/dev/null | jq -e '.status.availableReplicas >= 1 and .status.readyReplicas >= 1' >/dev/null; echo $?)
  LIMITADOR_OPERATOR_READY=$("${OC[@]}" get deployment limitador-operator-controller-manager -n kuadrant-system -o json 2>/dev/null | jq -e '.status.availableReplicas >= 1 and .status.readyReplicas >= 1' >/dev/null; echo $?)
  AUTHORINO_READY=$("${OC[@]}" get authorino authorino -n kuadrant-system -o json 2>/dev/null | jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1' >/dev/null; echo $?)
  LIMITADOR_READY=$("${OC[@]}" get limitador limitador -n kuadrant-system -o json 2>/dev/null | jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1' >/dev/null; echo $?)
  if [[ -n "$KUADRANT_NAME" && "$KUADRANT_OPERATOR_READY" == 0 && "$AUTHORINO_OPERATOR_READY" == 0 && "$LIMITADOR_OPERATOR_READY" == 0 && "$AUTHORINO_READY" == 0 && "$LIMITADOR_READY" == 0 ]]; then
    KUADRANT_SHARED=true
    printf 'shared=true\nkuadrant=%s\nreason=healthy ODH-managed Kuadrant, Authorino, and Limitador reused without ownership changes\n' "$KUADRANT_NAME" >"$OUT/kuadrant-shared.txt"
  else
    echo 'Kuadrant resources are present but not healthy; refusing to adopt or reinstall shared operators' >&2
    exit 1
  fi
else
  kustomize build "$KUADRANT_OPERATOR_REPO/config/install/openshift" | pin_kuadrant_catalog_image | normalize_kuadrant_olm | without_managed_gateway_crds | "${OC_LONG[@]}" apply -f - >"$OUT/kuadrant-install.log" 2>&1
fi
KUADRANT_DEADLINE=$((SECONDS + 300))
while ! "${OC[@]}" get deployment kuadrant-operator-controller-manager -n kuadrant-system -o json 2>/dev/null | jq -e '.status.availableReplicas >= 1 and .status.readyReplicas >= 1' >/dev/null; do
  (( SECONDS >= KUADRANT_DEADLINE )) && { echo "Kuadrant operator did not become Ready; diagnostics: $OUT/kuadrant-install.log" >&2; exit 1; }
  sleep 2
done

# Verify the installed OLM objects before any tenant fixture is created. A
# Ready operator from a floating or synthetic bundle is not qualification
# evidence: MaaS expects the v1.4.2 catalog and Authorino Operator v0.23.1.
KUADRANT_VERSION_EVIDENCE="$OUT/kuadrant-version-evidence"
mkdir -p "$KUADRANT_VERSION_EVIDENCE"
if [[ "$KUADRANT_SHARED" == true ]]; then
  "${OC[@]}" get csv -n kuadrant-system -o json >"$KUADRANT_VERSION_EVIDENCE/csv.json"
  "${OC[@]}" get kuadrant,authorino,limitador -n kuadrant-system -o json >"$KUADRANT_VERSION_EVIDENCE/shared-resources.json"
  printf '%s\n' 'shared ODH-managed Kuadrant stack; no CatalogSource is present and no operator resources were changed' >"$KUADRANT_VERSION_EVIDENCE/shared.txt"
fi
if [[ "$KUADRANT_SHARED" == false ]]; then
CATALOG_IMAGE=$("${OC[@]}" get catalogsource kuadrant-operator-catalog -n kuadrant-system -o jsonpath='{.spec.image}' 2>/dev/null || true)
printf 'expected=%s\nobserved=%s\n' "$KUADRANT_CATALOG_IMAGE" "$CATALOG_IMAGE" >"$KUADRANT_VERSION_EVIDENCE/catalog.txt"
[[ "$CATALOG_IMAGE" == "$KUADRANT_CATALOG_IMAGE" ]] || { echo "Kuadrant CatalogSource is not the pinned v1.4.2 digest; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2; exit 1; }
CSV_DEADLINE=$((SECONDS + 300))
while :; do
  "${OC[@]}" get csv -A -o json >"$KUADRANT_VERSION_EVIDENCE/csv.json"
  if jq -e '[.items[] | select(.metadata.namespace == "kuadrant-system" and .metadata.name == "kuadrant-operator.v1.4.2" and .status.phase == "Succeeded")] | length == 1' "$KUADRANT_VERSION_EVIDENCE/csv.json" >/dev/null &&
     jq -e '[.items[] | select(.metadata.namespace == "kuadrant-system" and .metadata.name == "authorino-operator.v0.23.1" and .status.phase == "Succeeded")] | length == 1' "$KUADRANT_VERSION_EVIDENCE/csv.json" >/dev/null &&
     jq -e '[.items[] | select(.metadata.namespace == "kuadrant-system" and .metadata.name == "limitador-operator.v0.17.1" and .status.phase == "Succeeded")] | length == 1' "$KUADRANT_VERSION_EVIDENCE/csv.json" >/dev/null; then
    break
  fi
  if (( SECONDS >= CSV_DEADLINE )); then
    echo "required Kuadrant/Authorino/Limitador CSVs did not become Succeeded; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
    exit 1
  fi
  sleep 3
done
jq '[.items[] | select(.metadata.namespace == "kuadrant-system" and (.metadata.name|test("kuadrant-operator|authorino-operator|limitador-operator"))) | {name:.metadata.name,version:.spec.version,phase:.status.phase,relatedImages:(.spec.relatedImages//[]|map(.image))}]' "$KUADRANT_VERSION_EVIDENCE/csv.json" >"$KUADRANT_VERSION_EVIDENCE/expected-images.json"
if jq -e '[.items[] | select(.metadata.namespace == "kuadrant-system" and (.metadata.name|test("kuadrant-operator|authorino-operator|limitador-operator"))) | (.spec.relatedImages//[] | .[].image) | select(test(":latest$"))] | length > 0' "$KUADRANT_VERSION_EVIDENCE/csv.json" >/dev/null; then
  echo "Kuadrant-related operand image is floating; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
fi
if false; then
"${OC[@]}" get pod -n kuadrant-system -o json >"$KUADRANT_VERSION_EVIDENCE/pods.json"
jq '[.items[] | select(.metadata.name|test("authorino|kuadrant|limitador")) | {name:.metadata.name,images:[.status.containerStatuses[]?.image],imageIDs:[.status.containerStatuses[]?.imageID]}]' "$KUADRANT_VERSION_EVIDENCE/pods.json" >"$KUADRANT_VERSION_EVIDENCE/running-images.json"
if jq -e '[.[] | .images[]? | select(test(":latest$"))] | length > 0' "$KUADRANT_VERSION_EVIDENCE/running-images.json" >/dev/null; then
  echo "Kuadrant-related running operand uses a floating image tag; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
fi
AUTHORINO_POD=$("${OC[@]}" get pod -n kuadrant-system -l authorino-resource=authorino -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[[ -n "$AUTHORINO_POD" ]] || { echo "Authorino operand pod is missing; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2; exit 1; }
if ! AUTHORINO_VERSION=$("${OC[@]}" exec -n kuadrant-system "$AUTHORINO_POD" -- authorino version 2>&1); then
  printf '%s\n' "$AUTHORINO_VERSION" >"$KUADRANT_VERSION_EVIDENCE/authorino-version.txt"
  echo "unable to query Authorino version; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
fi
printf '%s\n' "$AUTHORINO_VERSION" >"$KUADRANT_VERSION_EVIDENCE/authorino-version.txt"
grep -Eq "Authorino[[:space:]]+$AUTHORINO_RUNTIME_VERSION([[:space:]]|\()" "$KUADRANT_VERSION_EVIDENCE/authorino-version.txt" || {
  echo "Authorino runtime must report v$AUTHORINO_RUNTIME_VERSION; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
}
AUTHORINO_IMAGE_ID=$(jq -r '.[0].imageIDs[0] // ""' "$KUADRANT_VERSION_EVIDENCE/authorino-running-final.json" 2>/dev/null || true)
if [[ -z "$AUTHORINO_IMAGE_ID" ]]; then
  AUTHORINO_IMAGE_ID=$(jq -r '.items[] | select(.metadata.name|test("^authorino-")) | .status.containerStatuses[0].imageID' "$KUADRANT_VERSION_EVIDENCE/pods.json" | head -1)
fi
printf 'expected_runtime_version=%s\nexpected_runtime_digest=%s\nobserved_image_id=%s\n' "$AUTHORINO_RUNTIME_VERSION" "$AUTHORINO_RUNTIME_DIGEST" "$AUTHORINO_IMAGE_ID" >>"$KUADRANT_VERSION_EVIDENCE/authorino-version.txt"
[[ "$AUTHORINO_IMAGE_ID" == *"@$AUTHORINO_RUNTIME_DIGEST" ]] || {
  echo "Authorino runtime image digest does not match the catalog-resolved digest; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
}
fi
fi
# The pinned Kuadrant OpenShift bundle also contains sail.yaml, which creates
# a second Sail-managed Istio control plane. This harness owns the single
# pinned istio-system control plane above, so apply only the three independent
# Kuadrant configuration resources from the pinned checkout.
if [[ "$KUADRANT_SHARED" == false ]]; then
  for kuadrant_config in authorino.yaml limitador.yaml kuadrant.yaml; do
    "${OC_LONG[@]}" apply -f "$KUADRANT_OPERATOR_REPO/config/install/configure/standard/$kuadrant_config"
  done >"$OUT/kuadrant-configure.log" 2>&1
fi
if [[ "$KUADRANT_SHARED" == true ]]; then
  "${OC[@]}" get pod -n kuadrant-system -o json >"$KUADRANT_VERSION_EVIDENCE/pods.json"
  jq '[.items[] | select(.metadata.name|test("authorino|kuadrant|limitador")) | {name:.metadata.name,images:[.status.containerStatuses[]?.image],imageIDs:[.status.containerStatuses[]?.imageID]}]' "$KUADRANT_VERSION_EVIDENCE/pods.json" >"$KUADRANT_VERSION_EVIDENCE/running-images.json"
  if jq -e '[.[] | .images[]? | select(test(":latest$"))] | length > 0' "$KUADRANT_VERSION_EVIDENCE/running-images.json" >/dev/null; then
    echo "shared Kuadrant operand image is floating; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
    exit 1
  fi
else
AUTHORINO_DEADLINE=$((SECONDS + 300))
while :; do
  AUTHORINO_POD=$("${OC[@]}" get pod -n kuadrant-system -l authorino-resource=authorino -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "$AUTHORINO_POD" ]] && "${OC[@]}" get pod -n kuadrant-system "$AUTHORINO_POD" -o json 2>/dev/null | jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1' >/dev/null; then
    break
  fi
  (( SECONDS >= AUTHORINO_DEADLINE )) && { echo "Authorino operand did not become Ready; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2; exit 1; }
  sleep 3
done
"${OC[@]}" get pod -n kuadrant-system -o json >"$KUADRANT_VERSION_EVIDENCE/pods.json"
jq '[.items[] | select(.metadata.name|test("authorino|kuadrant|limitador")) | {name:.metadata.name,images:[.status.containerStatuses[]?.image],imageIDs:[.status.containerStatuses[]?.imageID]}]' "$KUADRANT_VERSION_EVIDENCE/pods.json" >"$KUADRANT_VERSION_EVIDENCE/running-images.json"
if jq -e '[.[] | .images[]? | select(test(":latest$"))] | length > 0' "$KUADRANT_VERSION_EVIDENCE/running-images.json" >/dev/null; then
  echo "Kuadrant-related running operand uses a floating image tag; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
fi
if ! AUTHORINO_VERSION=$("${OC[@]}" exec -n kuadrant-system "$AUTHORINO_POD" -- authorino version 2>&1); then
  printf '%s\n' "$AUTHORINO_VERSION" >"$KUADRANT_VERSION_EVIDENCE/authorino-version.txt"
  echo "unable to query Authorino version; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
fi
printf '%s\n' "$AUTHORINO_VERSION" >"$KUADRANT_VERSION_EVIDENCE/authorino-version.txt"
grep -Eq "Authorino[[:space:]]+$AUTHORINO_RUNTIME_VERSION([[:space:]]|\\()" "$KUADRANT_VERSION_EVIDENCE/authorino-version.txt" || {
  echo "Authorino runtime must report v$AUTHORINO_RUNTIME_VERSION; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
}
AUTHORINO_IMAGE_ID=$(jq -r --arg pod "$AUTHORINO_POD" '.items[] | select(.metadata.name == $pod) | .status.containerStatuses[0].imageID' "$KUADRANT_VERSION_EVIDENCE/pods.json")
printf 'expected_runtime_version=%s\nexpected_runtime_digest=%s\nobserved_image_id=%s\n' "$AUTHORINO_RUNTIME_VERSION" "$AUTHORINO_RUNTIME_DIGEST" "$AUTHORINO_IMAGE_ID" >>"$KUADRANT_VERSION_EVIDENCE/authorino-version.txt"
[[ "$AUTHORINO_IMAGE_ID" == *"@$AUTHORINO_RUNTIME_DIGEST" ]] || {
  echo "Authorino runtime image digest does not match the catalog-resolved digest; diagnostics: $KUADRANT_VERSION_EVIDENCE" >&2
  exit 1
}
fi
# Fail closed if a broad or stale configure step created a competing Sail
# control plane. The parent Istio resource must be absent in this topology.
SAIL_ISTIO_JSON=$("${OC[@]}" get istio.sailoperator.io -A -o json 2>/dev/null || true)
SAIL_ISTIO_COUNT=$(jq '.items | length' <<<"$SAIL_ISTIO_JSON" 2>/dev/null || printf '0')
if [[ "$SAIL_ISTIO_COUNT" -gt 0 ]]; then
  printf '%s\n' "$SAIL_ISTIO_JSON" >"$OUT/forbidden-sail-istio.json"
  echo "unexpected Sail Istio resource exists; sail.yaml must remain excluded: $OUT/forbidden-sail-istio.json" >&2
  exit 1
fi
# Authorino may become Ready just after the Kuadrant controller starts. Restart
# the controller once, through the normal Deployment lifecycle, so its
# dependency discovery is deterministic rather than relying on a fixed sleep.
if [[ "$KUADRANT_SHARED" == false ]]; then
  "${OC_LONG[@]}" rollout restart deployment/kuadrant-operator-controller-manager -n kuadrant-system >"$OUT/kuadrant-restart.log" 2>&1
  "${OC_LONG[@]}" rollout status deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s >>"$OUT/kuadrant-restart.log" 2>&1
fi

# Authorino can become Ready after the Kuadrant controller has already
# completed its initial dependency discovery.  Do not let a later request
# assertion observe an unauthenticated 200 while Kuadrant still reports a
# dependency failure.  The CR status is the state-based readiness contract;
# this wait is intentionally bounded and records the final status for review.
KUADRANT_READY_EVIDENCE="$OUT/kuadrant-ready.json"
KUADRANT_READY_DEADLINE=$((SECONDS + 300))
while :; do
  KUADRANT_STATUS=$("${OC[@]}" get kuadrant "$KUADRANT_NAME" -n kuadrant-system -o json 2>/dev/null || true)
  if [[ -n "$KUADRANT_STATUS" ]] && jq -e '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length == 1' <<<"$KUADRANT_STATUS" >/dev/null; then
    printf '%s\n' "$KUADRANT_STATUS" >"$KUADRANT_READY_EVIDENCE"
    break
  fi
  if (( SECONDS >= KUADRANT_READY_DEADLINE )); then
    printf '%s\n' "${KUADRANT_STATUS:-{}}" >"$KUADRANT_READY_EVIDENCE"
    echo "Kuadrant did not report Ready after Authorino and operand readiness; diagnostics: $KUADRANT_READY_EVIDENCE" >&2
    exit 1
  fi
  sleep 3
done

# The fresh CI cluster does not expose the internal registry by default. This
# route is run-owned and is removed by destroy.sh; it is not a production
# registry configuration.
if ! "${OC[@]}" get route "$OPENSHIFT_E2E_REGISTRY_ROUTE" -n openshift-image-registry >/dev/null 2>&1; then
  REGISTRY_SERVICE_CA=$("${OC[@]}" get configmap openshift-service-ca.crt -n openshift-image-registry -o jsonpath='{.data.service-ca\.crt}')
  "${OC_LONG[@]}" apply -f - <<EOF >"$OUT/registry-route.log"
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: $OPENSHIFT_E2E_REGISTRY_ROUTE
  namespace: openshift-image-registry
  labels:
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
spec:
  to: {kind: Service, name: image-registry}
  port: {targetPort: 5000}
  tls:
    termination: reencrypt
    destinationCACertificate: |-
$(printf '      %s' "${REGISTRY_SERVICE_CA//$'\n'/$'\n      '}")
EOF
else
  # Upgrade an earlier run-owned passthrough route to the verified reencrypt
  # contract; never mutate a route lacking this run's ownership label.
  OWNER=$("${OC[@]}" get route "$OPENSHIFT_E2E_REGISTRY_ROUTE" -n openshift-image-registry -o jsonpath='{.metadata.labels.external-model-praxis\.opendatahub\.io/run-id}')
  [[ "$OWNER" == "$OPENSHIFT_E2E_RUN_ID" ]] || { echo "refusing to modify foreign registry route" >&2; exit 1; }
  REGISTRY_SERVICE_CA=$("${OC[@]}" get configmap openshift-service-ca.crt -n openshift-image-registry -o jsonpath='{.data.service-ca\.crt}')
  "${OC[@]}" patch route "$OPENSHIFT_E2E_REGISTRY_ROUTE" -n openshift-image-registry --type=json -p="$(jq -cn --arg ca "$REGISTRY_SERVICE_CA" '[{op:"replace",path:"/spec/tls",value:{termination:"reencrypt",destinationCACertificate:$ca}}]')" >"$OUT/registry-route.log"
fi
"${OC[@]}" get route "$OPENSHIFT_E2E_REGISTRY_ROUTE" -n openshift-image-registry -o jsonpath='{.spec.host}{"\n"}' >"$OUT/registry-host.txt"
printf '%s\n' "$OUT"
