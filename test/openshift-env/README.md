# OpenShift External Model and Praxis validation

This directory provides a controller-owned OpenShift test environment for the
External Model to Praxis integration. It installs the required test stack,
deploys source-matched components, exercises the real Gateway request path, and
records evidence without changing production manifests.

The intended request path is:

```text
client -> OpenShift load balancer -> Gateway/Envoy -> Kuadrant/Authorino
       -> Praxis ExtProc -> tenant-local Praxis -> external provider fixture
```

The scripts are for disposable OpenShift qualification environments. They do
not install an OpenShift cluster and must not be used to replace components in
a shared or production cluster.

## What the suite validates

The executable suite validates the following behavior with real requests and
state-based checks:

- controller, tenant, ExternalProvider, ExternalModel, HTTPRoute, ExtProc, and
  Praxis readiness;
- verified TLS at the public Gateway;
- unauthenticated requests are rejected;
- MaaS API-key creation, use, and revocation;
- authenticated routing to two credential-enforcing provider fixtures;
- provider selection changes without restarting Praxis;
- unknown-model handling;
- semantic configuration no-op behavior;
- invalid-overlay last-known-good behavior;
- declared, recomputed, and mounted overlay convergence;
- tenant Praxis ServiceAccount denial of Secret API access;
- credential-pattern scans over functional evidence; and
- reset to the first provider after validation.

The current qualification is single-tenant. Multi-tenant MaaS authorization
dispatch, credential rotation, IPP-to-Praxis transition and rollback, and
additional provider authentication strategies require separate qualification.
The current integration does not support migrating a tenant between
namespaces or relocating an existing tenant. It assumes the MaaS AITenant
remains in place and its resolved `status.tenantNamespace` remains stable;
those operations require separate ownership-transfer and reprojection
semantics and are not demonstrated here.

## Resource ownership

The harness distinguishes resources it creates from shared platform resources.

Run-owned resources include the test Gateway, provider fixtures, controller
deployment, temporary RBAC, registry project, test certificates, compatibility
resources, and evidence. These resources carry the run identifier and may be
removed only after their ownership is verified.

Shared resources include platform CRDs, the shared MaaS AITenant, platform
namespaces, Istio, Kuadrant, Authorino, Limitador, KServe, and other installed
operators. The harness may configure a documented shared resource when required
for qualification, but it must first record its identity and original state.
Cleanup restores that state instead of deleting the shared resource.

The cleanup scripts never remove finalizers to force deletion.

## Prerequisites

Required tools:

- `oc`
- `kubectl`
- `docker`
- `skopeo`
- `helm`
- `kustomize`
- `openssl`
- `jq`
- `yq`
- `gettext` (provides `envsubst`)
- `curl`
- `tar`
- `sha256sum`
- `timeout` (from GNU coreutils)
- `go`
- `make`
- `git`
- `bash`

The current `oc` session must be authenticated as a cluster administrator on a
disposable OpenShift cluster. The cluster must have working default storage,
an integrated image registry, and sufficient capacity for the platform and
test workloads.

The scripts expect sibling source checkouts for:

- ai-gateway-controller;
- models-as-a-service;
- Praxis AI;
- Praxis ExtProc;
- KServe;
- Kuadrant Operator; and
- LLM-Katan source provenance.

Use immutable source revisions and image digests. Do not qualify floating image
tags or dirty source without recording the source and dirty-content hashes in
the generated image evidence.

## Isolated credentials and state

Create an isolated kubeconfig from the active session:

```sh
cd test/openshift-env
export OPENSHIFT_E2E_STATE="$PWD/.state/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OPENSHIFT_E2E_STATE"
oc config view --raw --minify > "$OPENSHIFT_E2E_STATE/kubeconfig"
chmod 600 "$OPENSHIFT_E2E_STATE/kubeconfig"
export OPENSHIFT_KUBECONFIG="$OPENSHIFT_E2E_STATE/kubeconfig"
```

The state directory is ignored by Git. Do not place login commands, bearer
tokens, API keys, or kubeconfig contents in the README, shell history, evidence,
or command-line arguments.

The functional suite creates an ephemeral MaaS API key through an in-cluster
client, supplies it over standard input, and revokes it on normal exit, failure,
or interruption. Secret values and Authorization headers must not be printed or
stored as evidence.

## Required inputs

Set source roots to pinned checkouts:

```sh
export PRAXIS_REPO=/path/to/praxis-ai
export PRAXIS_EXTPROC_REPO=/path/to/praxis-extproc
export MAAS_CONTROLLER_REPO=/path/to/models-as-a-service
export KSERVE_REPO=/path/to/kserve
export KUADRANT_OPERATOR_REPO=/path/to/kuadrant-operator
```

For current qualification, `MAAS_CONTROLLER_REPO` must be a clean checkout
of the merged `main` branch. Praxis AI and Praxis ExtProc are built from their
checked-out integration sources; record the intended branch or detached
revision before provisioning. KServe and Kuadrant remain pinned dependency
checkouts selected by the bootstrap workflow. The harness checks dependency
cleanliness and records source identity, but it does not silently switch a
dirty checkout or infer that a branch name is equivalent to a source pin.

Before each build, record the repository path, remote URL, branch or detached
state, HEAD SHA, tracked diff hash, and untracked-content hash. Image
publication then records the immutable registry digest used by the workload.
The digest is the executable artifact and the source SHA is provenance; a
mutable tag is never qualification evidence. A cold-fetch workflow must select
the configured branch or revision directly and repeat the same provenance
capture.

The Praxis ExtProc and MaaS checkouts must be clean. The controller and Praxis
worktree hashes are recorded when local changes are intentionally qualified.

The supported controller image override must be an immutable digest:

```sh
export OPENSHIFT_E2E_CONTROLLER_IMAGE='registry.example/controller@sha256:<digest>'
export KATAN_IMAGE='ghcr.io/nerdalert/llm-katan@sha256:11379a1ec2fd69dc121eada6c544eb423a7c074414507dc1d474f4abba9df75a'
```

When the controller override is omitted, provisioning builds it from the
current checkout. Praxis, ExtProc, MaaS API, and MaaS controller are built from
their configured source checkouts. Provisioning publishes these images to a
run-owned registry project, resolves their pushed digests, and deploys those
digests.

## MaaS compatibility proof

OpenShift qualification requires a MaaS controller that implements the Praxis
opt-in contract. `preflight.sh` requires immutable proof for:

- the `maas.opendatahub.io/payload-processing-type: praxis` selection;
- skipping tenant IPP resources for a Praxis-selected tenant;
- ownership-safe release and cleanup of IPP resources; and
- a source or image identity matching the MaaS implementation under test.

Do not bypass this gate by installing a second MaaS controller or replacing a
managed MaaS deployment without an explicit, reversible test plan.

The source-matched MaaS `main` controller deployment may not install a tenant
validating webhook. In that source topology, provisioning records the absence
explicitly and gates tenant creation on a server-side dry-run after controller
readiness. If a MaaS installation does publish
`maas-validating-webhook-configuration`, provisioning instead requires its
Deployment, ready endpoints, Service, CA bundle, serving certificate, and
server-side dry-run to converge before creating the tenant. This distinction
is source-provenance dependent; the harness never treats an absent webhook as
a healthy webhook or silently fabricates one.

## End-to-end workflow

Run the scripts from this directory:

```sh
./preflight.sh
./bootstrap.sh
./provision.sh
./e2e.sh
./demo.sh
./inspect.sh
./destroy.sh
```

`preflight.sh` checks tools, authentication, source inputs, immutable image
references, cluster access, and MaaS compatibility before creating tenant test
resources.

`bootstrap.sh` installs or verifies the platform dependencies required by the
test. It enforces one Istio control plane, excludes Sail-managed duplicate
Istio installation, verifies webhook trust and live certificates, and records
operator and operand provenance.

`provision.sh` builds or resolves images, configures registry access, applies
controller CRDs before fixtures, deploys the source-matched MaaS and controller
components, prepares the shared MaaS AITenant for Praxis, and creates the provider and
authorization fixtures.

The MaaS overlay merges the run-specific immutable image inputs into the
`maas-parameters` ConfigMap generated by canonical MaaS `main`. This is
intentional: current MaaS source owns that ConfigMap, so `behavior: merge`
preserves the source resource contract and avoids a duplicate-generator
failure. If a future MaaS revision removes the source generator, update the
overlay against that source revision and record the change before provisioning;
do not repair this with an untracked live ConfigMap.

### Praxis handoff and protected gateway namespaces

For a controlled handoff, keep the Praxis annotation on the existing AITenant
and start a MaaS build that publishes
`status.conditions[type=IPPResourcesReleased].status=True` after its
ownership-gated IPP writers and conflicting routes are gone. The AI Gateway
controller waits for that condition (and understands the existing cleanup
marker published by earlier MaaS builds) before creating same-named Praxis
payload-processing resources. Do not first restore IPP from saved YAML, add
ownership metadata by hand, or run two routing-state writers at once.

Managed OpenShift installations may reject a controller-created
NetworkPolicy in the shared gateway namespace. The run-owned controller
manifest therefore passes the explicit `--skip-network-policy=true` option;
the default remains policy management. This option assumes equivalent
platform networking is already provided and must be paired with an explicit
connectivity check. It is not an admission bypass and the harness never
creates a substitute policy. The long-term installation decision belongs in
the ODH operator/deployment topology.

`e2e.sh` performs the machine-readable qualification. It uses bounded probes,
does not retry received HTTP responses, and atomically records failures,
including the active assertion when interrupted.

`demo.sh` presents the finalized machine-readable qualification as a
human-readable narrative. It does not duplicate validation, and it never turns
missing evidence into a pass. The displayed evidence path is relative to the
run root; secrets, authorization headers, cookies, and kubeconfig contents are
never displayed.

The narrative follows the real request path:

```text
client -> Gateway/Envoy -> Kuadrant/Authorino -> Praxis ExtProc
       -> tenant-local Praxis -> credential-enforcing provider fixture
```

Provider A and Provider B are controlled test endpoints used to demonstrate a
declared routing update. They are not a load-balancing or automatic-failover
qualification. Both run the pinned Katan image with `--validate-keys` and
custom service-ca-issued TLS certificates on port 443; the expected provider
credential is configured by the fixture and is never written to evidence.
The Service annotations request the certificates, and provisioning waits for
both Secrets before the Pods are considered usable. The in-cluster client
trusts the Gateway CA and the provider service CA, and direct fixture probes
use hostname-verified HTTPS. OpenShift therefore exercises the same HTTPS
provider contract as the production renderer; no plaintext exception or
insecure verification flag is used.

The qualified provider contract is explicitly OpenAI Chat Completions:
`provider: openai`, `apiFormat: openai-chat`, and
`/v1/chat/completions`. This integration does not support or qualify
`/v1/responses`; a Responses-capable implementation inside the Praxis
repository does not extend the MaaS/controller contract. Do not label a
Responses endpoint as `openai-chat`.

For the optional real OpenAI qualification, the public model identity must be
consistent across the authorization chain: ExternalModel `spec.modelName`,
`MaaSModelRef.metadata.name`, subscription `modelRefs`, MaaSAuthPolicy
`modelRefs`, request path, and request body all use `gpt-4o-mini`. The
temporary OpenAI fixture is separate from the `demo` fixture; changing only
the ExternalModel while retaining the `demo` MaaSModelRef or subscription
produces an authorization denial. The OpenShift controller template adds the
temporary OpenAI upstream to its explicit cluster allowlist; generated
policies and live status are not patched.

For each declared provider, the controller renders the ExternalProvider
endpoint as the authoritative HTTP authority, uses its hostname only for TLS
SNI, and preserves an explicit port in the dial endpoint (the OpenShift
fixtures use `:443`). The OpenShift E2E captures and checks the mounted
`praxis-config` before requests. TLS verification is never disabled. Katan
listens on unprivileged container port `8443`; its Service exposes port `443`,
and the service-ca certificate is mounted into the fixture and the run-owned
Praxis trust bundle. Direct credential probes therefore use the same
hostname-verified HTTPS path as routed requests.

Katan is a test-only OpenAI Chat Completions fixture. It receives its
fixture credential through the run-owned tenant Secret/configuration path;
that credential is not the MaaS client key and is never written to evidence.
Katan proves credential enforcement and routing behavior, but does not prove
public external HTTPS transport or every OpenAI request/response schema detail.

The OpenShift E2E suite directly probes the selected provider without a
credential and with a wrong credential (both must return HTTP 401). It also
sends the valid MaaS caller key through stdin while adding a conflicting
caller `x-api-key` header; that Gateway request must return HTTP 200 with the
selected provider attribution. These checks prove backend credential
enforcement and x-api-key resistance. The separate caller `Authorization`
override is `NOT_DEMONSTRATED`: this fixture uses the sole `Authorization`
header for MaaS caller authentication, so duplicate-header ordering would be
ambiguous rather than a valid proof. It remains a follow-up until an
independent supported caller-authentication mechanism exists. Credential
rotation, OAuth2, and SigV4 are also out of scope.

Render the narrative from the finalized qualification evidence after the
qualification completes:

```sh
source "$OPENSHIFT_E2E_STATE/run.env"
LATEST_EVIDENCE=$(find "$OPENSHIFT_E2E_EVIDENCE_ROOT" -mindepth 1 -maxdepth 1 \
  -type d -name 'e2e-*' -print | sort | tail -n 1)
./test/openshift-env/demo.sh --non-interactive --evidence "$LATEST_EVIDENCE"
```

To intentionally run a new qualification and render it in one command:

```sh
./test/openshift-env/e2e.sh
source "$OPENSHIFT_E2E_STATE/run.env"
LATEST_EVIDENCE=$(find "$OPENSHIFT_E2E_EVIDENCE_ROOT" -mindepth 1 -maxdepth 1 \
  -type d -name 'e2e-*' -print | sort | tail -n 1)
./test/openshift-env/demo.sh --non-interactive --evidence "$LATEST_EVIDENCE" \
  > OPENSHIFT-DEMO-OUTPUT.txt
```

Without `--evidence`, `demo.sh` runs `e2e.sh` first. Use that mode only when
an additional qualification run is intentional; use the finalized evidence
mode above for a presentation or review of an existing run.

To render an existing finalized run without contacting OpenShift:

```sh
./test/openshift-env/demo.sh --evidence "$OPENSHIFT_E2E_EVIDENCE_ROOT/e2e-<timestamp>-<pid>"
```

The renderer accepts a run directory or its `results.json`. It preserves the
live qualification exit status, renders completed assertions after a failure,
and reports credential rotation, two-tenant MaaS authorization, IPP transition
and rollback, OAuth2/SigV4, and commercial-provider behavior as unproven unless
separate evidence exists.

The formatting regression test uses deterministic fixture evidence and checks
PASS, FAIL, missing evidence, `NOT DEMONSTRATED`, required test titles, path
redaction, and credential-shaped output:

```sh
./test/openshift-env/test-demo-format.sh
```

`inspect.sh` records the deployed state and relevant status without collecting
credential values.

`destroy.sh` verifies ownership, revokes remaining test credentials, restores
shared state, deletes run-owned resources, and returns nonzero when cleanup is
incomplete.

## Installation order

The automated install order is intentional:

1. Validate the isolated kubeconfig, source revisions, and compatibility proof.
2. Install or verify Gateway API and certificate management.
3. Install exactly one supported Istio control plane and verify admission TLS.
4. Install the pinned Kuadrant catalog without a Sail-created Istio instance.
5. Verify Kuadrant, Authorino, and Limitador operator and runtime provenance.
6. Install or verify KServe and the MaaS CRDs and RBAC.
7. Build and publish source-matched MaaS, controller, Praxis, and ExtProc images.
8. Grant exact ServiceAccounts access to the run-owned registry project.
9. Deploy images by resolved digest and wait for rollouts.
10. Apply controller-owned CRDs before creating ExternalProvider or
    ExternalModel resources.
11. Reuse the source-created shared MaaS AITenant for single-tenant validation.
12. Apply the Praxis opt-in and wait for the resolved tenant namespace.
13. Create provider, subscription, policy, Gateway, and TLS fixtures.
14. Wait for policies, routes, overlays, mounts, and workloads to converge.
15. Run functional qualification and the narrative demo.
16. Reset routing, inspect evidence, and perform ownership-checked cleanup.

## External Model resources and rendering

Stable run-owned platform resources are checked in under
`test/openshift-env/manifests/` as numbered `*.yaml.tmpl` files. Shared
External Model identities, the optional OpenAI CR chain, the persistent client
base, and the credential-safe request helper are under `test/external-model/`.
OpenShift renders shared provider and client resources explicitly, while
keeping its service-ca-backed Katan HTTPS, registry/SCC/image-pull handling,
and public Gateway TLS local to this harness. Kind intentionally retains
explicit plaintext Katan and HTTP Gateway behavior.

For the next cold validation, use a new state directory and the documented
workflow from this directory:

```sh
OPENSHIFT_E2E_STATE="$PWD/.openshift-state/<run-id>" ./preflight.sh
OPENSHIFT_E2E_STATE="$PWD/.openshift-state/<run-id>" ./bootstrap.sh
OPENSHIFT_E2E_STATE="$PWD/.openshift-state/<run-id>" ./provision.sh
OPENSHIFT_E2E_STATE="$PWD/.openshift-state/<run-id>" ./e2e.sh
OPENSHIFT_E2E_STATE="$PWD/.openshift-state/<run-id>" ./demo.sh --non-interactive
OPENSHIFT_E2E_STATE="$PWD/.openshift-state/<run-id>" ./destroy.sh
```

The optional OpenAI CR chain is rendered only when an environment-specific
qualification explicitly requests `openai.yaml.tmpl`; it is never part of the
base provisioning sequence.

The renderer requires GNU gettext (`envsubst`); install the `gettext` package
alongside the existing `yq` prerequisite. Provisioning validates each rendered
fixture with `oc apply --dry-run=server` and saves the result before applying
it. The static render test requires `yq` and performs client-side YAML
validation without a cluster.

For each rendered template, provisioning writes separate
`server-dry-run-*.log` and `apply-*.log` files before and during application.
The server dry run is bounded to 120 seconds and a failure prevents that
template from being applied.

`provision.sh` invokes `render-manifests.sh` with an explicit allowlist for
each template and applies the rendered files from the current run's ignored
evidence directory. It renders early templates with the provisional namespace,
then renders tenant-dependent templates after MaaS reports the resolved tenant
namespace. A normal run therefore remains:

```sh
./test/openshift-env/preflight.sh
./test/openshift-env/bootstrap.sh
./test/openshift-env/provision.sh
./test/openshift-env/e2e.sh
./test/openshift-env/demo.sh
./test/openshift-env/inspect.sh
./test/openshift-env/destroy.sh
```

To exercise the renderer without a cluster, run:

```sh
./test/openshift-env/test-render-manifests.sh
```

The renderer fails on unset variables, rejects unresolved placeholders, and
never performs unrestricted substitution. Rendered YAML is deployment
evidence under run state and must not be committed. Credential-bearing Secret
creation, Gateway certificates, discovered ServiceAccount bindings, image
publication, source-pinned platform manifests, and server-side readiness
checks remain in shell because they require opaque values or live identities.
Templates contain references only; they contain no credential data.

## Default MaaS API service

The source-matched MaaS installation creates the shared MaaS AITenant and canonical
`maas-system/maas-api` Service. Single-tenant qualification uses that native
Service when its selector, ready endpoints, and service-ca certificate are
valid.

The API listener can become ready slightly after its EndpointSlice is marked
ready. Provisioning therefore performs the Authorino-to-MaaS check as a
bounded transport-convergence gate: connection-refused or unavailable
endpoint observations are retried for the documented deadline, while any
received HTTP response is recorded and evaluated immediately. The probe must
finish with HTTP 200 and `ssl_verify_result=0`; it is not a request retry
mechanism. The complete attempt log is retained under the run's `provision`
evidence directory so an interrupted cold run can resume from the affected
step without hiding the original failure.

A run-owned TLS compatibility proxy is permitted only when a non-primary
tenant-qualified MaaS API lacks the shared callback address expected by the
generated policy. The proxy may provide TLS name compatibility only. It must
not manufacture authorization responses, disable verification, redirect calls
between tenants, or conceal a failed MaaS callback.

This adapter does not prove multi-tenant callback dispatch. That remains a
separate MaaS integration concern shared by IPP and Praxis paths.

## Registry authorization

Attaching a pull Secret to a ServiceAccount does not by itself grant access to
an OpenShift image stream. Provisioning creates a run-specific pull Secret and
an exact `system:image-puller` RoleBinding in the image project for each
ServiceAccount that needs an image.

Before accepting a rollout, the harness records:

- the RoleBinding subject;
- the ServiceAccount identity;
- the original and test `imagePullSecrets`; and
- the running pod image ID.

Cleanup restores the original ServiceAccount configuration and removes only the
run-labeled Secret and RoleBinding after verifying their ownership.

## Provider fixture contract

The provider fixtures run the pinned LLM-Katan image with credential
enforcement enabled,
OpenAI-compatible test endpoints. They use a writable `/tmp` home directory to
work under OpenShift's restricted security policy.

Provider A and Provider B exist to prove a routing change, not load balancing
or latency behavior. Both providers are declared before the baseline request.
The ExternalModel initially selects Provider A, then changes to Provider B. The
suite verifies overlay convergence, Provider B attribution, and an unchanged
Praxis pod identity and restart count.

The qualified credential mapping is deliberately narrow:

```text
provider type: openai
API format:    openai-chat
CRD auth type: apikey
Praxis action: inject the projected token as a bearer credential
```

The overlay contains only a Secret reference. Secret bytes reach Praxis through
a tenant-local projected volume. Unsupported provider/API combinations, SigV4,
OAuth2, and unknown authentication types fail closed.

## Overlay convergence

Before sending a request after a provider change, the suite requires two stable
observations of all of the following:

- the expected provider in the controller ConfigMap;
- the expected overlay generation and declared digest;
- semantic digest recomputation using the controller implementation;
- the same digest and provider in the file mounted by Praxis; and
- stable Praxis pod identity and restart count.

This prevents a request from racing ahead of the projected ConfigMap update.
Raw file hashes are not equivalent to the controller's semantic digest and must
not be substituted.

## Evidence and result rules

Each run writes to a unique evidence directory under `OPENSHIFT_E2E_STATE`.
Evidence should include:

- source revisions and dirty-content hashes;
- built and deployed image digests;
- operator, operand, CRD, and webhook provenance;
- readiness and route conditions;
- sanitized HTTP status and provider attribution;
- overlay generations and digests;
- Praxis UID and restart counts;
- cleanup results; and
- a machine-readable assertion result.

An assertion may pass only from an observed result. A received HTTP response is
never retried. Transport status `000` may be retried only within a bounded
Gateway readiness probe. Missing functionality must be recorded as
`NOT_DEMONSTRATED` or a failure, never inferred from another assertion.

The exit and signal traps convert an unfinished `RUNNING` result into `FAIL`,
preserve the active assertion, revoke any active key, and leave existing failed
evidence intact.

## Troubleshooting

Start with the first failed assertion and its evidence. Do not patch generated
routes, overlays, policies, or authorization responses to make a run pass.

Common checks:

```sh
oc --kubeconfig "$OPENSHIFT_KUBECONFIG" get nodes
oc --kubeconfig "$OPENSHIFT_KUBECONFIG" get pods -A
oc --kubeconfig "$OPENSHIFT_KUBECONFIG" get gateway,httproute -A
oc --kubeconfig "$OPENSHIFT_KUBECONFIG" get authpolicy -A
oc --kubeconfig "$OPENSHIFT_KUBECONFIG" get deployment,service,endpointslice -A
```

For image-pull failures, verify the exact ServiceAccount, RoleBinding subject,
registry project, pull Secret, and deployed digest.

For admission failures, verify there is exactly one Istio control plane and
that the webhook Service, endpoints, CA bundle, live certificate, and SNI agree.

For authorization failures, distinguish the stages:

1. public Gateway TLS;
2. API-key validation callback;
3. subscription or policy evaluation;
4. ExtProc processing;
5. Praxis provider selection and credential injection; and
6. provider response.

Record sanitized status and identity metadata only. Do not print the API key or
Authorization header while diagnosing a request.

For overlay failures, compare the controller ConfigMap, declared semantic
digest, recomputed digest, mounted Praxis file, expected provider, pod UID, and
restart count. Wait for stable convergence rather than adding request retries.

## Static validation

Run the controller and harness checks before publishing changes:

```sh
go test ./...
go vet ./...
make lint

./test/external-model/test-static.sh
./test/kind-env/test-provider-credentials.sh
./test/openshift-env/test-request-wrapper.sh
./test/openshift-env/test-render-manifests.sh

for file in test/openshift-env/*.sh; do
  bash -n "$file"
done

shellcheck test/openshift-env/*.sh
./test/openshift-env/test-bootstrap-single-istio.sh
./test/openshift-env/test-destroy-order.sh
git diff --check
```

Static checks do not replace a cold OpenShift run. Changes to provisioning,
shared-state restoration, credentials, or cleanup require a fresh deployment,
functional qualification, demo, and cleanup verification on a disposable
cluster.
