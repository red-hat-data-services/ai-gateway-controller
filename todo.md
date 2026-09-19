# ai-gateway-controller — Konflux / E2E notes

**Dynamic MaaS e2e branch:** see [test/e2e/TODO.md](test/e2e/TODO.md) for excluded tests, upstream MaaS requirements, and Konflux follow-ups.

**Vendored e2e branch:** `ci/maas-e2e-konflux-group-test` (sync script + copied tests).

## Quick run (dynamic checkout)

```bash
AI_GATEWAY_CONTROLLER_IMAGE=quay.io/opendatahub/odh-ai-gateway-controller:odh-pr \
  ./test/e2e/scripts/prow_run_ai_gateway_controller_test.sh
```

Refresh MaaS pin: `MAAS_UPDATE_LOCK=true bash test/e2e/scripts/fetch-maas-e2e.sh`
