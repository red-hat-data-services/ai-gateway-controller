# Routing-overlay hot-swap e2e (port plan M3)

End-to-end proof, on a local kind cluster, that the Go producer side of the
ExternalModel reconciler port speaks the exact wire contract the praxis AI
data plane consumes:

1. **Cross-implementation digest agreement** — `pkg/resolver` + `pkg/envelope`
   render a `routing-overlay.json` envelope whose RFC 8785 digest validates in
   the Rust `intelligent_route` filter (praxis-ai `origin/main`, hot-reload PR
   #540). The overlay ConfigMap is created before praxis starts: an invalid
   cold-start envelope fails filter construction, so a Ready pod is itself
   evidence of envelope acceptance.
2. **Hot-swap without restart** — applying a generation-2 envelope that moves
   `echo-one` from `provider-katan-a` to `provider-katan-b` changes which
   llm-katan echo backend serves, with the praxis pod UID unchanged and
   `restartCount == 0`. Path: `kubectl apply` → kubelet ConfigMap projection
   (`..data` symlink flip) → inotify → validate → `ArcSwap`.
3. **Unknown model → 404** from `intelligent_route` (no backend involved).
4. **Last-known-good retention** — a corrupted `content_digest` is rejected on
   reload and the previously serving snapshot keeps routing.

## Layout

| Path | Purpose |
|------|---------|
| `kind.yaml` | Cluster config; kubelet `Watch` strategy for fast ConfigMap projection |
| `manifests/` | Namespace, two llm-katan echo backends, praxis pipeline + deployment |
| `render-overlay/` | Stands in for the reconciler's publish step: builds typed `ExternalModel`/`ExternalProvider` objects, runs the real `resolver.Resolve` + `envelope.Render`, writes the envelope |
| `run.sh` | Orchestration + assertions (`--destroy` tears down) |

## Run

```console
# praxis image with overlay hot-reload (from a praxis-ai checkout on origin/main):
git worktree add /tmp/praxis-overlay-e2e origin/main --detach
docker build -t praxis-ai:overlay-e2e -f Containerfile /tmp/praxis-overlay-e2e

# then:
./run.sh   # builds llm-katan:e2e from $LLMKATAN_REPO (default: ~/code/redhat/llm-katan)
           # if absent, loads both images into kind, deploys, asserts
./run.sh --destroy
```

Typical first run is a few minutes (image loads into kind); reruns reuse the
cluster and cached images. All kubectl calls are pinned to
`--context kind-overlay-e2e` on purpose — do not "simplify" that away.

## Wire-contract notes

- Cluster names follow the reconciler convention `provider-<ExternalProvider
  CR name>` and must pre-exist in the praxis `load_balancer` config — overlay
  reload swaps candidates only, never clusters (#540 scope rule).
- The overlay ConfigMap mount must **not** use `subPath`: the watcher keys on
  the projected volume's `..data` symlink replacement.
- `source_generation` must strictly increase on content change; `run.sh`
  chains generation 1 → 2 through `render-overlay` prev-revision flags.
- Rust tolerates unknown additive envelope/candidate fields but rejects
  unknown fields inside `credential`, and recomputes the digest over the
  **raw** wire value (filtered to `candidates`/`local_site`/`network`/
  `selection_policy`) — so whatever bytes we emit are what gets hashed; we
  must never emit fields our Go digest struct would drop.

## Findings from the first real cross-plane run

- **Auth vocabulary gap (§6 open item).** The CRD `auth.type` enum
  (`apikey|sigv4|oauth2`) and the overlay wire vocabulary (praxis accepts
  `bearer_token` **only**, `descriptor.rs` `validate_credential`) do not
  overlap. `envelope.strategyFor` therefore renders no credential for every
  CRD auth type today; the fix is either a wider praxis strategy enum or
  moving credentials out of the envelope. Needs a decision at the freeze.
- **In-cluster backends need `allow_private_endpoints`.** Praxis refuses
  `load_balancer` endpoints that resolve into pod/service CIDRs unless
  `insecure_options.allow_private_endpoints: true`. Dogfood never hit this
  because every cluster there is a public hostname; any gateway fronting
  in-cluster model servers will.

## M1 golden vectors

Done: the Rust-side fixtures from praxis-ai
`tests/fixtures/overlay-contract/v1/` (source commit
`1ef8a53ee9f2fd33db40862d4c70180ec80b20a6`) are vendored under
`pkg/envelope/testdata/overlay-contract/v1/` and driven by
`pkg/envelope/golden_vectors_test.go` against
`envelope.ComputeDigestFromWire` — digest agreement is now asserted on every
CI run, not only when this kind e2e executes. The e2e keeps its distinct
value: it proves the live consumer accepts what the live producer emits;
the vectors pin the digest function itself against regressions, including
raw-value semantics (unknown additive candidate fields hash, `generated_at`
does not) and the legacy/envelope shape-detection hazard.
