# 0001. ExternalModel/ExternalProvider → Praxis: two-plane authority and the routing-overlay contract

- **Status:** PROPOSED — pending agreement by control-plane, data-plane, and MaaS owners
- **Date:** 2026-09-08
- **Deciders:** MaaS (Yossi Ovadia, Noy Itzikowitz) · ai-gateway-controller team (Jamie Land) · data plane (Praxis)
- **Format:** Nygard ADR template ([architecture-decision-record/architecture-decision-record](https://github.com/architecture-decision-record/architecture-decision-record))
- **Companion docs:** *ExternalModel/ExternalProvider Reconciler Port Plan v2* (implementation detail, parity inventory, milestones) · *IPP → Praxis Migration Plan — RHOAI 3.6* (workstream split)

## Context

RHOAI 3.6 moves the external-model data plane from IPP (gateway-api-inference-extension + BBR) to Praxis (`praxis-extproc`). Constraints that shape this decision:

1. **The CRDs are a frozen user contract.** `ExternalModel`/`ExternalProvider` (`inference.opendatahub.io/v1alpha1`) already exist in clusters. Backward compatibility without auto-migration is a hard requirement: existing objects must keep working, and no object may be rewritten by the cutover.
2. **Consumers read status.** `maas-api`/`maas-controller` attach Kuadrant policies to `status.httpRouteName` gated on `status.phase` — that contract survives the migration unchanged.
3. **Runtime dual-deploy cutover is already agreed.** The operator installs both `maas-controller` and this controller; the flip per tenant is maas-controller tear-down → this controller takes over. A short downtime window is accepted; a soft-downtime variant is the recommendation for 3.6.
4. **Ownership split is agreed.** MaaS owns the reconciler logic (resolution, overlay rendering, side-effects, status); the ai-gateway-controller team owns the runtime around it (manager, manifests, image, E2E harness).
5. Both planes' details must be **documented and agreed** before implementation continues — this record is that document. Decisions below are marked *accepted-in-practice* where code already implements them (with evidence), and *open* where a call is still needed.

## Decision

### D1 — Two-plane authority, single writer *(accepted-in-practice)*

The controller is the **sole writer** of routing state; Praxis is a **read-only consumer** of the published overlay. Post-cutover, the overlay is the *only* model→provider selector for new-world traffic. The Envoy plane (HTTPRoute + Istio ServiceEntry/DestinationRule + ExternalName Service) remains as upstream plumbing (Host rewrite, TLS) and as the policy-attachment surface — it is never a second selector.

One resolved route set feeds **both** renders in the same reconcile, and the overlay ConfigMap is applied **last** (it is the one artifact whose inconsistency fails at request time, not reload time).

*Why:* two live selectors can diverge silently; a single dynamic-config surface matches the contract the Praxis routing filter was built to consume; keeping the Envoy side-effects preserves `httpRouteName` so `maas-api` needs zero changes.

### D2 — Backward-compatible types: mirror, don't import; no migration by construction *(accepted-in-practice)*

The CRD types are a **frozen mirror** in this repo's own `api/` package (not an import of the IPP module), kept in sync by a CI drift-golden test while both controllers coexist. **Nothing in this design rewrites existing objects; no migration path exists** — the "no auto-migration" requirement is satisfied by construction, not by a migration script.

*Why:* importing would pin this repo to the module the migration supersedes (a dead dependency once IPP freezes). The CRD shape is contractually frozen, which is exactly the condition under which a copy is cheap and permanent. The mirror also keeps every type crossing the handoff boundary self-owned, so the interface freeze cannot leak.

### D3 — The routing-overlay envelope is the wire contract (v1) *(accepted-in-practice; contract, not code)*

The controller publishes a `routing-overlay.json` envelope with:

- `schema_version: "1.0.0"` and a **content-addressed revision**: `sha256` over the RFC 8785 (JCS)-canonicalized overlay content (`network`, `local_site`, `candidates`, and `selection_policy` when present). Provenance fields (who rendered it, when, which generation) are deliberately **not** in the digest — only the routing content is.
- The consumer (Praxis) **recomputes the digest and rejects on mismatch** — every published state is independently verifiable, which is what makes last-known-good retention and tamper detection possible.
- `source_generation` is strictly monotonic: it advances only when the digest changes.
- Credential objects are **references, never bytes**, and the shape is exactly `{strategy, secretRef{name, namespace, key}}` — the consumer rejects unknown fields inside them.
- Cross-language byte-compatibility is pinned by **12 golden digest vectors** shared between the Go CI and the Rust CI (the same fixtures run in both), so a producer/consumer drift fails a build on either side.

*Why:* content addressing turns "is the ConfigMap what we published?" from a trust assumption into a hash check; generation chaining makes partial applies observable (revision lagging the CR generation = mid-apply).

### D4 — Publish semantics *(accepted-in-practice)*

The envelope lives in a ConfigMap (`routing-overlay`, data key `routing-overlay.json`), server-side-applied by a single field manager. The mount into Praxis must **not** use `subPath` — the projected volume's `..data` symlink swap is the reload trigger. Publish is idempotent: byte-identical envelopes are not rewritten, and `rendered_at` is inherited (not re-stamped) when the digest is unchanged, so a no-op reconcile cannot churn the ConfigMap or trigger a reload. A baseline whose bytes no longer hash to its declared revision is **refused loudly**, never chained from.

*Why:* the data plane hot-swaps on file change; churn is a needless reload, and a tampered baseline silently laundered into generation N+1 would destroy the audit trail.

### D5 — Weights in 3.6: uniform only, guarded at render time *(accepted-in-practice)*

Within a model, all surviving provider weights must be equal (unset ≡ 1). A non-uniform set **refuses the whole reconcile**: the model goes `Ready=False` with a `WeightUnsupported` condition and the published generation does not advance. Weight-0 keeps IPP's semantics (the candidate is omitted — a disabled provider).

*Why:* the Praxis picker has no weighted-random policy, so a 70/30 canary would silently route 50/50. The guard converts that into a loud failure at `kubectl apply` time. The only sanctioned path to proportional weights is a `Weighted` picker policy upstreamed to Praxis — faking weights by duplicating candidates is forbidden (it breaks session-affinity identity).

### D6 — Status contract: the controller is the sole status writer, and it only attests what it can verify

`Ready=True` requires **all** of: refs resolved, provider resources applied, HTTPRoute applied, overlay applied (partial-apply contract — a step-N failure leaves the previously distributed envelope in place). The overlay condition is named **`OverlayDistributed`** (carrying digest + generation), not "serving": the controller can truthfully attest the ConfigMap was applied with a given digest; whether the data plane is actually serving it is a request-time observation Praxis does not yet report, and a status contract must not be able to lie.

*Why:* two writers on one status is the bug class the old stack already has, and `Ready` gaining the meaning "the route actually exists" means policies can never attach against a rejected route.

### Open — decisions this record deliberately leaves to the team

| # | Question | Current posture | Leaning |
|---|----------|-----------------|---------|
| O1 | **Credential strategies.** The CRD says `apikey\|sigv4\|oauth2`; the wire contract accepts only `bearer_token`. Until resolved, unrepresentable types render **no credential** (routing still works; injection stays at the provider gateway). | Omit, no wire lie | Widen the Praxis strategy enum |
| O2 | **AITenant contract.** Which field decides praxis-vs-maas mode per tenant, and does the controller watch AITenant or is the flip purely operator-driven? | Not designed | Watch + filter (enables soft-downtime) |
| O3 | **Downtime budget.** Hard ~1–2 min, or a soft-downtime variant for 3.6 (old plane keeps routing until the new plane confirms the overlay loaded)? | Not decided | Soft-downtime for 3.6 |
| O4 | **Model aliases.** One ExternalModel answering to several body-model names: emit duplicate-identity candidates (producer-side) or an alias-resolution step in the filter? | Unchanged IPP behavior | Producerside, revisit at CF |

## Consequences

**Positive**

- Zero migration, zero object mutation at cutover — the backward-compat requirement holds by construction (D2).
- Every published overlay state is hash-verifiable on both sides of the wire, and the pin is enforced in **both** CIs (D3).
- Partial applies and torn states are observable, not silent (D4/D6).
- One selector authority — no divergence between planes by construction (D1).
- `maas-api`/`maas-controller` keep working unchanged against `httpRouteName` (D1/D6).

**Costs and obligations**

- Two repos must keep the API mirror in sync until cutover — the drift-golden test is mandatory while both controllers exist (D2).
- Adding a new provider is a two-step flow: the pipeline's `load_balancer` cluster must exist **before** the overlay may reference it (the renderer rejects unknown clusters). Document in the install guide.
- No weighted canaries until the Praxis picker supports them (D5) — users who need a 70/30 split today get a loud refusal, not a silent even split.
- The publisher must read back and re-digest its own ConfigMap before every publish (D4) — one extra API read per reconcile, negligible.
- This controller's `Ready` is stronger than IPP's — a stricter consumer contract, which is the point (D6).

**Revisit triggers**

- Praxis config composition lands (xDS-style distribution) → reconsider the ConfigMap as the transport (D3/D4).
- A `Weighted` picker policy is upstreamed → lift the uniform-only guard (D5).
- A second consumer of the resolver appears → extract `pkg/resolver` into its own module.
- Cutover completes → the mirror can be retired to a single source of truth.
