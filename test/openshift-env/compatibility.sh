#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
STATE=${OPENSHIFT_E2E_STATE:-"$ROOT/.openshift-state"}
# shellcheck disable=SC1091
source "$STATE/run.env"
OC=(timeout --foreground 45s oc --kubeconfig "${OPENSHIFT_KUBECONFIG:-$STATE/kubeconfig}")
OUT="$OPENSHIFT_E2E_EVIDENCE_ROOT/compatibility"
mkdir -p "$OUT"
SERVICE_NAME=maas-api
TARGET=maas-api-xmp-${OPENSHIFT_E2E_RUN_ID}
NAMESPACE=maas-system
target_json=$("${OC[@]}" -n "$NAMESPACE" get deployment "$TARGET" -o json)
printf '%s' "$target_json" | jq '{name:.metadata.name,namespace:.metadata.namespace,uid:.metadata.uid,selector:.spec.selector.matchLabels,podLabels:.spec.template.metadata.labels,ports:.spec.template.spec.containers[0].ports}' >"$OUT/target-deployment.json"
selector=$(printf '%s' "$target_json" | jq -c '.spec.template.metadata.labels | with_entries(select(.key == "maas.opendatahub.io/tenant-instance"))')
[[ "$selector" != '{}' ]] || { echo "target MaaS API has no tenant-instance selector" >&2; exit 1; }
existing=$("${OC[@]}" -n "$NAMESPACE" get service "$SERVICE_NAME" -o json 2>/dev/null || true)
if [[ -n "$existing" ]]; then
  owner=$(printf '%s' "$existing" | jq -r '.metadata.labels["external-model-praxis.opendatahub.io/run-id"] // empty')
  [[ "$owner" == "$OPENSHIFT_E2E_RUN_ID" ]] || { echo "refusing to modify non-run-owned $NAMESPACE/$SERVICE_NAME" >&2; exit 1; }
fi
cat <<EOF | "${OC[@]}" apply -f - >"$OUT/apply.log"
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    external-model-praxis.opendatahub.io/compatibility-adapter: shared-maas-callback
  annotations:
    service.beta.openshift.io/serving-cert-secret-name: maas-api-serving-cert
spec:
  ports:
  - name: https
    port: 8443
    protocol: TCP
    targetPort: https
  selector:
    maas.opendatahub.io/tenant-instance: $TARGET
EOF
deadline=$(( $(date +%s) + 120 ))
while :; do
  ready=$("${OC[@]}" -n "$NAMESPACE" get endpointslice -l kubernetes.io/service-name="$SERVICE_NAME" -o json 2>/dev/null | jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' || printf 0)
  cert=$("${OC[@]}" -n "$NAMESPACE" get secret maas-api-serving-cert -o json 2>/dev/null | jq -r 'if .data["tls.crt"] and .data["tls.key"] then "yes" else "no" end' || printf no)
  [[ "$ready" -ge 1 && "$cert" == yes ]] && break
  (( $(date +%s) >= deadline )) && { echo "compatibility Service did not converge: ready=$ready certificate=$cert" >&2; exit 1; }
  sleep 2
done
"${OC[@]}" -n "$NAMESPACE" get service "$SERVICE_NAME" -o json | jq '{name:.metadata.name,namespace:.metadata.namespace,uid:.metadata.uid,labels:.metadata.labels,annotations:.metadata.annotations,selector:.spec.selector,ports:.spec.ports}' >"$OUT/service.json"
"${OC[@]}" -n "$NAMESPACE" get endpointslice -l kubernetes.io/service-name="$SERVICE_NAME" -o json | jq '{items:[.items[]|{ports:.ports,endpoints:[.endpoints[]|{addresses:.addresses,ready:.conditions.ready}]}]}' >"$OUT/endpoints.json"
"${OC[@]}" -n "$NAMESPACE" get secret maas-api-serving-cert -o json | jq '{name:.metadata.name,namespace:.metadata.namespace,uid:.metadata.uid,resourceVersion:.metadata.resourceVersion,keys:(.data|keys),annotations:.metadata.annotations}' >"$OUT/certificate-secret.json"
CERT_FILE="$OUT/serving.crt"
"${OC[@]}" -n "$NAMESPACE" get secret maas-api-serving-cert -o jsonpath='{.data.tls\.crt}' | base64 -d >"$CERT_FILE"
openssl x509 -in "$CERT_FILE" -noout -subject -issuer -dates -fingerprint -sha256 -ext subjectAltName >"$OUT/certificate.txt"
grep -q 'DNS:maas-api.maas-system.svc' "$OUT/certificate.txt" || { echo "certificate missing required SAN" >&2; exit 1; }
grep -q 'DNS:maas-api.maas-system.svc.cluster.local' "$OUT/certificate.txt" || { echo "certificate missing cluster-local SAN" >&2; exit 1; }
# MaaS owns the target Deployment and may reconcile its certificate mount back
# to the canonical tenant-specific certificate. Do not mutate that Deployment.
# A run-owned TLS proxy gives the shared callback hostname its matching
# service-ca certificate and forwards to the canonical Service with verified
# upstream TLS.
cat <<EOF | "${OC[@]}" apply -f - >"$OUT/proxy-apply.log"
apiVersion: v1
kind: ConfigMap
metadata:
  name: maas-api-callback-proxy
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
data:
  nginx.conf: |
    pid /tmp/nginx.pid;
    events {}
    http {
      client_body_temp_path /tmp/client_temp;
      proxy_temp_path /tmp/proxy_temp;
      fastcgi_temp_path /tmp/fastcgi_temp;
      uwsgi_temp_path /tmp/uwsgi_temp;
      scgi_temp_path /tmp/scgi_temp;
      server {
        listen 8443 ssl;
        ssl_certificate /etc/tls/tls.crt;
        ssl_certificate_key /etc/tls/tls.key;
        location / {
          proxy_pass https://$TARGET.$NAMESPACE.svc.cluster.local:8443;
          proxy_ssl_server_name on;
          proxy_ssl_name $TARGET.$NAMESPACE.svc.cluster.local;
          proxy_ssl_verify on;
          proxy_ssl_trusted_certificate /etc/ca/service-ca.crt;
          proxy_set_header Host $TARGET.$NAMESPACE.svc.cluster.local;
        }
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: maas-api-callback-proxy
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
spec:
  replicas: 1
  selector: {matchLabels: {app: maas-api-callback-proxy}}
  template:
    metadata:
      labels:
        app: maas-api-callback-proxy
        external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
    spec:
      automountServiceAccountToken: false
      containers:
      - name: proxy
        image: nginx:1.27-alpine@sha256:65645c7bb6a0661892a8b03b89d0743208a18dd2f3f17a54ef4b76fb8e2f2a10
        imagePullPolicy: IfNotPresent
        ports: [{name: https, containerPort: 8443}]
        readinessProbe: {httpGet: {scheme: HTTPS, path: /health, port: https}}
        securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
        volumeMounts:
        - {name: config, mountPath: /etc/nginx/nginx.conf, subPath: nginx.conf, readOnly: true}
        - {name: tls, mountPath: /etc/tls, readOnly: true}
        - {name: ca, mountPath: /etc/ca, readOnly: true}
      volumes:
      - {name: config, configMap: {name: maas-api-callback-proxy}}
      - {name: tls, secret: {secretName: maas-api-serving-cert}}
      - {name: ca, configMap: {name: openshift-service-ca.crt}}
EOF
"${OC[@]}" -n "$NAMESPACE" rollout restart deployment/maas-api-callback-proxy >"$OUT/proxy-restart.log"
cat <<EOF | "${OC[@]}" apply -f - >"$OUT/proxy-service-apply.log"
apiVersion: v1
kind: Service
metadata:
  name: $SERVICE_NAME
  namespace: $NAMESPACE
  labels:
    app.kubernetes.io/managed-by: external-model-praxis-openshift-e2e
    external-model-praxis.opendatahub.io/run-id: $OPENSHIFT_E2E_RUN_ID
spec:
  ports: [{name: https, port: 8443, targetPort: https}]
  selector: {app: maas-api-callback-proxy}
EOF
"${OC[@]}" -n "$NAMESPACE" rollout status deployment/maas-api-callback-proxy --timeout=180s >"$OUT/proxy-rollout.log" 2>&1
echo "compatibility adapter ready: $NAMESPACE/$SERVICE_NAME -> $TARGET via run-owned TLS proxy" | tee "$OUT/result.txt"
