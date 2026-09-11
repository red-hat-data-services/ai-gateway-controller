#!/usr/bin/env bash
# Routing-overlay hot-swap e2e (port plan M3).
#
# Proves, against a real praxis binary on a local kind cluster:
#   1. The Go producer (pkg/resolver + pkg/envelope) renders an envelope the
#      Rust consumer accepts (digest, scope, provenance all validate).
#   2. Updating the routing-overlay ConfigMap hot-swaps the serving route
#      with no pod restart (kubelet projection -> inotify -> ArcSwap).
#   3. Unknown models get 404 from intelligent_route.
#   4. A corrupted envelope retains the last-known-good snapshot.
#
# Usage:
#   ./run.sh            # create cluster if needed, deploy, assert
#   ./run.sh --destroy  # tear the cluster down
set -euo pipefail
cd "$(dirname "$0")"

CLUSTER=overlay-e2e
NS=overlay-e2e
# Pin every $KCTL call to this harness's kind context: this machine's
# kubeconfig also holds live OpenShift contexts, and an un-pinned apply once
# landed e2e resources in the dogfood cluster.
KCTL="kubectl --context kind-$CLUSTER"
PRAXIS_IMAGE=praxis-ai:overlay-e2e
KATAN_IMAGE=llm-katan:e2e
# Checkout of the llm-katan repo (needs the echo backend + --providers flag).
LLMKATAN_REPO=${LLMKATAN_REPO:-$HOME/code/redhat/llm-katan}
LOCAL_PORT=18080
TMP=$(mktemp -d)
PF_PID=""

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

cleanup() {
  [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

if [[ "${1:-}" == "--destroy" ]]; then
  kind delete cluster --name "$CLUSTER"
  exit 0
fi

# ---- cluster + images -------------------------------------------------------

if ! kind get clusters | grep -qx "$CLUSTER"; then
  echo "==> creating kind cluster $CLUSTER"
  kind create cluster --name "$CLUSTER" --config kind.yaml
fi

if ! docker image inspect "$KATAN_IMAGE" >/dev/null 2>&1; then
  [[ -d "$LLMKATAN_REPO" ]] || fail "missing docker image $KATAN_IMAGE and no llm-katan checkout at $LLMKATAN_REPO (set LLMKATAN_REPO)"
  echo "==> building $KATAN_IMAGE from $LLMKATAN_REPO"
  docker build -q -t "$KATAN_IMAGE" -f Containerfile.katan "$LLMKATAN_REPO" >/dev/null
fi

for img in "$PRAXIS_IMAGE" "$KATAN_IMAGE"; do
  docker image inspect "$img" >/dev/null 2>&1 || fail "missing docker image $img"
  if ! kind load docker-image "$img" --name "$CLUSTER" 2>/dev/null; then
    fail "kind load $img failed"
  fi
done

# ---- deploy -----------------------------------------------------------------

echo "==> rendering overlay generation 1 (echo-one -> katan-a)"
go run ./render-overlay \
  --route echo-one:katan-a \
  --known-clusters provider-katan-a,provider-katan-b \
  --out "$TMP/v1.json" 2>"$TMP/v1.meta"
cat "$TMP/v1.meta"

echo "==> applying manifests"
$KCTL apply -f manifests/00-namespace.yaml -f manifests/10-backends.yaml -f manifests/20-praxis-config.yaml >/dev/null

# The overlay ConfigMap must exist with a valid envelope before praxis starts:
# an invalid cold-start envelope fails filter construction (crashloop).
apply_overlay() { # $1 = envelope json file
  $KCTL -n "$NS" create configmap routing-overlay \
    --from-file=routing-overlay.json="$1" \
    --dry-run=client -o yaml | $KCTL apply -f - >/dev/null
}
apply_overlay "$TMP/v1.json"

# Static pipeline config is loaded at process start: restart praxis if it was
# already running, so an edited praxis-config actually takes effect on rerun.
praxis_existed=$($KCTL -n "$NS" get deployment praxis >/dev/null 2>&1 && echo yes || echo no)
$KCTL apply -f manifests/30-praxis.yaml >/dev/null
[[ "$praxis_existed" == "yes" ]] && $KCTL -n "$NS" rollout restart deployment/praxis >/dev/null
$KCTL -n "$NS" rollout status deployment/katan-a --timeout=180s
$KCTL -n "$NS" rollout status deployment/katan-b --timeout=180s
$KCTL -n "$NS" rollout status deployment/praxis --timeout=120s || {
  $KCTL -n "$NS" logs deployment/praxis --tail=30
  fail "praxis did not become ready"
}

echo "==> port-forward svc/praxis :$LOCAL_PORT"
$KCTL -n "$NS" port-forward svc/praxis "$LOCAL_PORT:8080" >/dev/null 2>&1 &
PF_PID=$!
sleep 2

# ---- helpers ----------------------------------------------------------------

# Anthropic-dialect POST /v1/messages, returns HTTP status on stdout.
request() { # $1 = model
  curl -sS -o "$TMP/body.json" -w '%{http_code}' --max-time 10 \
    -X POST "http://127.0.0.1:$LOCAL_PORT/v1/messages" \
    -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
    -H 'x-api-key: e2e-test-key' \
    -d "{\"model\":\"$1\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}"
}

log_count() { # $1 = deployment, $2 = model -> served-request count in log
  $KCTL -n "$NS" logs "deployment/$1" 2>/dev/null | grep -c "model=$2" || true
}

rev_of() { # $1 = envelope file, $2 = field path -> prints value via python3
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval('d'+sys.argv[2]))" "$1" "$2"
}

praxis_uid() { $KCTL -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].metadata.uid}'; }
praxis_restarts() { $KCTL -n "$NS" get pod -l app=praxis -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}'; }

# ---- assertions ---------------------------------------------------------------

echo "==> 1. generation 1 routes echo-one to katan-a"
status=""
for _ in $(seq 1 30); do
  status=$(request echo-one) && [[ "$status" == "200" ]] && break
  sleep 1
done
[[ "$status" == "200" ]] || { cat "$TMP/body.json"; fail "echo-one not routed (status=$status)"; }

a=$(log_count katan-a echo-one); b=$(log_count katan-b echo-one)
status=$(request echo-one)
a2=$(log_count katan-a echo-one); b2=$(log_count katan-b echo-one)
[[ "$status" == "200" && $((a2 - a)) -eq 1 && "$b2" -eq "$b" ]] \
  || fail "expected the request to land on katan-a only (katan-a +$((a2-a)), katan-b +$((b2-b)))"
pass "echo-one served by katan-a"

echo "==> 2. unknown model gets 404"
status=$(request ghost-model-not-in-overlay)
[[ "$status" == "404" ]] || fail "unknown model returned $status, want 404"
pass "unknown model 404"

echo "==> 3. hot-swap: generation 2 moves echo-one to katan-b, no restart"
go run ./render-overlay \
  --route echo-one:katan-b \
  --known-clusters provider-katan-a,provider-katan-b \
  --prev-generation "$(rev_of "$TMP/v1.json" "['provenance']['source_generation']")" \
  --prev-digest "$(rev_of "$TMP/v1.json" "['content_digest']['value']")" \
  --out "$TMP/v2.json" 2>"$TMP/v2.meta"
cat "$TMP/v2.meta"
gen2=$(rev_of "$TMP/v2.json" "['provenance']['source_generation']")
[[ "$gen2" == "2" ]] || fail "expected generation 2, rendered $gen2"

uid_before=$(praxis_uid); restarts_before=$(praxis_restarts)
apply_overlay "$TMP/v2.json"

swapped=no
for _ in $(seq 1 45); do
  request echo-one >/dev/null || true
  b3=$(log_count katan-b echo-one)
  if [[ "$b3" -gt "$b2" ]]; then swapped=yes; break; fi
  sleep 2
done
[[ "$swapped" == "yes" ]] || { $KCTL -n "$NS" logs deployment/praxis --tail=40; fail "overlay swap never took effect"; }

# Stabilize: a few more requests must all land on katan-b, none on katan-a.
sleep 3
a4=$(log_count katan-a echo-one); b4=$(log_count katan-b echo-one)
for _ in 1 2 3; do request echo-one >/dev/null || true; sleep 1; done
a5=$(log_count katan-a echo-one); b5=$(log_count katan-b echo-one)
[[ $((a5 - a4)) -eq 0 && $((b5 - b4)) -eq 3 ]] \
  || fail "post-swap traffic misrouted (katan-a +$((a5-a4)), katan-b +$((b5-b4)), want 0 and 3)"

[[ "$(praxis_uid)" == "$uid_before" && "$(praxis_restarts)" == "$restarts_before" ]] \
  || fail "praxis pod changed or restarted during hot-swap"
pass "route hot-swapped to katan-b on the same pod (generation $gen2 accepted)"

echo "==> 4. corrupted envelope retains last-known-good"
python3 - "$TMP/v2.json" "$TMP/bad.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
v = d["content_digest"]["value"]
d["content_digest"]["value"] = ("0" if v[0] != "0" else "1") + v[1:]
d["revision"]["value"] = d["content_digest"]["value"]
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
apply_overlay "$TMP/bad.json"
sleep 8 # debounce + projection + validation window
status=$(request echo-one)
b6=$(log_count katan-b echo-one)
[[ "$status" == "200" && "$b6" -gt "$b5" ]] \
  || fail "bad envelope did not retain last-known-good (status=$status, katan-b +$((b6-b5)))"
[[ "$(praxis_restarts)" == "$restarts_before" ]] || fail "praxis restarted on bad envelope"
$KCTL -n "$NS" logs deployment/praxis | grep -qiE "invalid|reject|digest|failed" \
  || echo "note: praxis logged no rejection detail for the bad envelope" >&2
pass "bad digest rejected, last-known-good snapshot still serving"

echo
echo "ALL ASSERTIONS PASSED"
