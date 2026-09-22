# External Models with ExtProc: retained-cluster demo

This demo tells the External Model story from a platform engineer’s point of
view. It runs locally, but inference requests originate in one persistent,
restricted client pod inside the retained Kind cluster.

## User story

As a platform engineer, I want to change an External Model’s provider without
restarting its gateway, interrupting requests, or exposing provider credentials.

The demo proves the routing increment: authenticated traffic crosses the Gateway,
Kuadrant, tenant-local ExtProc, and a mock provider; provider routing can
change; malformed routing preserves the last-known-good state; and one tenant’s
mutation does not interrupt another tenant.

Grid is not involved. This is a single-cluster, tenant-scoped integration. The
existing IPP path remains the default for tenants that have not selected the
feature-gated ExtProc path.

## Architecture

```text
REQUEST PATH

Client Pod -> Gateway / Envoy -> Kuadrant / Authorino
          -> tenant-local post-auth ExtProc -> provider backend
          -> external-model backend

CONTROL PATH

ExternalModel + ExternalProvider
          -> ai-gateway-controller
          -> Service / ServiceEntry / DestinationRule / HTTPRoute
          -> reference-only routing overlay
          -> ExtProc overlay hot reload
```

`ai-gateway-controller` builds transport and routing state. Kuadrant
authenticates and authorizes the caller. Tenant-local ExtProc selects the
provider and injects the reference-only credential; Envoy clears its route
cache, reselects the trusted provider route, and forwards to the provider.

## Prerequisites and commands

Run from the controller repository:

```bash
./test/kind-env/run.sh --preflight
./test/kind-env/run.sh --provision
```

The provisioner creates the dedicated `kind-external-model-two-plane` context,
builds/loads the pinned local images, and leaves the environment available.

Run the interactive demo:

```bash
./test/kind-env/demo.sh --context kind-external-model-two-plane
```

Run it without prompts:

```bash
./test/kind-env/demo.sh --context kind-external-model-two-plane --non-interactive
```

Reset only the run-owned fixtures (without recreating the cluster):

```bash
./test/kind-env/demo.sh --context kind-external-model-two-plane --reset
```

Inspect the retained environment:

```bash
kubectl --context kind-external-model-two-plane get pods -A
kubectl --context kind-external-model-two-plane -n models-as-a-service \
  get externalmodel,externalprovider,httproute,service,deployment,configmap
kubectl --context kind-external-model-two-plane -n maas-system \
  get pod external-model-demo-client
```

Destroy only the run-owned cluster when inspection is complete:

```bash
./test/kind-env/run.sh --destroy
```

The demo does not use laptop port-forwards, repeated `kubectl run --rm`, host
networking, or a global trust-store change. The client pod remains so the cluster
can be inspected after the demo.

## Stages and what they prove

Each stage prints `GOAL`, `STARTING STATE`, `RESULT`, and a short explanation.
State-based waits are bounded. A received HTTP failure is recorded as a result;
it is not retried to manufacture a pass.

1. **Topology** — records Gateway, tenant, backend, overlay, and ExtProc state.
2. **Authentication** — demonstrates unauthenticated rejection, creates a demo
   key inside the client pod using verified CA trust, and sends an authenticated
   request.
3. **Provider A** — sends a real request through the complete chain.
4. **Hot swap to B** — mutates the run-owned ExternalModel, waits for a new
   overlay generation, and verifies the ExternalModel ExtProc pod
   identity/restart count.
5. **Semantic no-op** — generates a provider watch event and compares routing
   content before and after reconciliation.
6. **Invalid overlay** — submits malformed run-owned overlay data and verifies
   that the prior valid route continues serving, then restores the valid object.
7. **Tenant isolation** — sends Tenant B traffic before and after Tenant A’s
   mutation and verifies both ExtProc service accounts are denied Secret API reads.
8. **Credential behavior** — reports `NOT DEMONSTRATED` unless live projected
   Secret rotation is part of the current qualified runtime scope. It never
   simulates rotation.
9. **Summary** — calculates the demo assertion total from the evidence array and
   prints retained-cluster inspection commands.

The demo’s `results.json` is written atomically and includes one record for each
stage. Credential rotation and IPP transition/rollback are not silently counted
as routing-demo passes when they are outside the executable scope.

## Namespaces and security

The normal layout is:

| Area | Namespace | Contents |
|---|---|---|
| Gateway/policy/ExtProc | `maas-system` / `kuadrant-system` | Gateway, Envoy, Kuadrant, Authorino, Limitador, ExtProc, provider backend fixtures |
| Tenant A | `models-as-a-service` | ExternalModel, ExternalProvider, HTTPRoute, tenant-local ExtProc, overlay, projected provider references |
| Tenant B | `ai-tenant-tenant-b` | Independent model, route, tenant-local ExtProc, overlay, and provider references |
| Demo client | `maas-system` | Persistent restricted request client; no service-account token |

Provider values are never printed, placed in evidence, or added to overlays.
Only references and non-secret observations are shown. The client uses the
run-owned CA for the MaaS API HTTPS request; it does not use `-k`, `--insecure`,
HTTP downgrade, or a global CA bypass.

## Included and excluded scope

Included in the routing increment are ExternalModel/ExternalProvider reconciliation,
transport resources, HTTPRoute behavior and prefix rewrite, authenticated request
traversal, provider hot swap, last-known-good overlay handling, semantic no-op,
and two-tenant mutation isolation.

The following are not claimed by this demo unless explicitly qualified by a
separate suite:

- projected provider credential A→B rotation without an ExtProc restart;
- caller provider-header override protection at a credential-enforcing backend;
- complete existing IPP path → ExtProc opt-in transition and rollback;
- independent provider endpoint-health detection;
- SigV4, OAuth2, Azure, Vertex, and Bedrock certification;
- multi-site Grid discovery/routing;
- OpenShift service-ca, SCC, projected tokens, disconnected images, and operator lifecycle.

The demo does not fabricate controller status. A failed stage stops the demo,
preserves its evidence path, and identifies the failed boundary. The retained
cluster is for inspection and qualification, not production use.

## Troubleshooting by boundary

| Symptom | First inspection |
|---|---|
| Client pod does not become Ready | `kubectl --context kind-external-model-two-plane -n maas-system describe pod external-model-demo-client` |
| Authenticated request is rejected | Authorino/Kuadrant policy, MaaS API key response, and Gateway access logs |
| Provider A/B request fails | HTTPRoute parents, overlay digest/generation, ExtProc logs, and backend Service endpoints |
| Overlay does not converge | Controller status, ConfigMap annotations/data, and mounted overlay file |
| ExternalModel ExtProc restarts during swap | Deployment rollout history and pod UID/restart evidence |
| Tenant B fails after Tenant A mutation | Tenant B route/overlay/status and the request result recorded in `results.json` |

On failure, the demo prints the evidence directory. Inspect that directory before
resetting or destroying anything.
