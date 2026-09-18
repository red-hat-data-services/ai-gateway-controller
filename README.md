# ai-gateway-controller

Installs the `praxis-extproc` dataplane manifests. Deployed by
`ai-gateway-operator` as a sibling of `maas-controller`.

See [DESIGN.md](./DESIGN.md) for scope, architecture rationale, and what is
explicitly deferred. Read `DESIGN.md` before adding code.

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the PR process, CI checks, and
development setup.

## Production image contract

The ODH operator and release packaging own the images used by an installed
controller. They must provide `praxis-ai-image` as an immutable digest through
`config/self/default/params.env`; the controller Deployment passes that value
to `--praxis-image`. The corresponding Praxis AI image must also be declared as
a related image so disconnected mirroring includes it.

The controller intentionally has no mutable fallback for this value and fails
startup when it is absent. Kind and OpenShift qualification harnesses may
provide explicit run-specific image overrides, but those inputs are not a
substitute for operator wiring in a production installation.

## Kind integration environment

The [Kind environment](./test/kind-env/README.md) provides reproducible
functional integration and routing validation using pinned source revisions
and locally loaded images. It is isolated from production manifests and
records evidence for every qualification run.
