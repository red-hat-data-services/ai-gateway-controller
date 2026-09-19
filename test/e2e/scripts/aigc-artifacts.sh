#!/usr/bin/env bash
# ai-gateway-controller-only e2e artifact hooks (not in upstream MaaS).
set -euo pipefail

_AIGC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

collect_maas_must_gather() {
  local dest="${1:-${ARTIFACTS_DIR:-${ARTIFACT_DIR:-}}/gather-maas}"
  local logfile="${2:-${ARTIFACTS_DIR:-${ARTIFACT_DIR:-}}/maas-must-gather.log}"
  mkdir -p "$(dirname "$logfile")" "$dest"
  if ! command -v oc >/dev/null 2>&1 && ! command -v kubectl >/dev/null 2>&1; then
    echo "  Skipping MaaS must-gather (oc/kubectl not found)" >>"$logfile"
    return 0
  fi
  echo "Collecting MaaS diagnostics to $dest (log: $logfile) ..."
  {
    echo "=== MaaS must-gather started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    "${_AIGC_SCRIPT_DIR}/collect-maas-must-gather.sh" "$dest"
    echo "=== MaaS must-gather finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  } >>"$logfile" 2>&1 || true
  echo "  MaaS must-gather complete (see $logfile)"
}

collect_must_gather() {
  local dest="${1:-$ARTIFACTS_DIR/gather-openshift}"
  local logfile="${2:-$ARTIFACTS_DIR/must-gather.log}"
  mkdir -p "$(dirname "$logfile")" "$dest"
  collect_maas_must_gather "${ARTIFACTS_DIR:-${ARTIFACT_DIR:-}}/gather-maas" \
    "${ARTIFACTS_DIR:-${ARTIFACT_DIR:-}}/maas-must-gather.log"
  if ! command -v oc >/dev/null 2>&1; then
    echo "  Skipping OpenShift must-gather (oc not found)" >>"$logfile"
    return 0
  fi
  echo "Collecting OpenShift must-gather to $dest (log: $logfile) ..."
  {
    echo "=== must-gather started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    oc adm must-gather --dest-dir "$dest"
    echo "=== must-gather finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
  } >>"$logfile" 2>&1 || true
  echo "  must-gather complete (see $logfile)"
}

_aigc_kubectl() {
  if command -v kubectl >/dev/null 2>&1; then
    kubectl "$@"
  elif command -v oc >/dev/null 2>&1; then
    oc "$@"
  else
    return 127
  fi
}

# Extend $ARTIFACTS_DIR/maas-crs/ with DSC, HTTPRoutes, and Gateways using the
# same kubectl get $crd -A -o yaml pattern as MaaS auth_utils collect_maas_crs.
collect_aigc_maas_crs_extensions() {
  local outdir="${ARTIFACTS_DIR}/maas-crs"
  mkdir -p "$outdir"
  echo "Collecting AIGC cluster CR extensions to $outdir"

  local redact_cmd=(cat)
  if [[ "$(type -t redact_tokens 2>/dev/null)" == "function" ]]; then
    redact_cmd=(redact_tokens)
  fi

  local saved=0
  _save_crd_yaml() {
    local crd="$1"
    local artifact_name="$2"
    local outfile="$outdir/${artifact_name}.yaml"
    : >"$outfile"

    local yaml=""
    yaml="$(_aigc_kubectl get "$crd" -A -o yaml 2>/dev/null || true)"
    if [[ -z "$yaml" ]] || echo "$yaml" | grep -q 'items: \[\]'; then
      yaml="$(_aigc_kubectl get "$crd" -o yaml 2>/dev/null || true)"
    fi
    if [[ -n "$yaml" ]] && ! echo "$yaml" | grep -q 'items: \[\]'; then
      echo "$yaml" | "${redact_cmd[@]}" >>"$outfile"
      saved=$((saved + 1))
      echo "  Saved ${artifact_name}.yaml"
    fi
    if [[ ! -s "$outfile" ]]; then
      rm -f "$outfile"
    fi
  }

  _save_crd_yaml "datascienceclusters.datasciencecluster.opendatahub.io" "datascienceclusters"

  local dsci_crd yaml outfile
  outfile="$outdir/dscinitializations.yaml"
  : >"$outfile"
  for dsci_crd in \
    dscinitializations.dscinitialization.opendatahub.io \
    dscinitializations.datasciencecluster.opendatahub.io; do
    if ! _aigc_kubectl api-resources -o name 2>/dev/null | grep -qx "$dsci_crd"; then
      continue
    fi
    yaml="$(_aigc_kubectl get "$dsci_crd" -A -o yaml 2>/dev/null || true)"
    if [[ -z "$yaml" ]] || echo "$yaml" | grep -q 'items: \[\]'; then
      yaml="$(_aigc_kubectl get "$dsci_crd" -o yaml 2>/dev/null || true)"
    fi
    if [[ -n "$yaml" ]] && ! echo "$yaml" | grep -q 'items: \[\]'; then
      echo "$yaml" | "${redact_cmd[@]}" >>"$outfile"
      saved=$((saved + 1))
      echo "  Saved dscinitializations.yaml (from ${dsci_crd})"
      break
    fi
  done
  if [[ ! -s "$outfile" ]]; then
    rm -f "$outfile"
  fi

  _save_crd_yaml "httproutes.gateway.networking.k8s.io" "httproutes"
  _save_crd_yaml "gateways.gateway.networking.k8s.io" "gateways"

  if [[ "$saved" -eq 0 ]]; then
    echo "  No AIGC cluster CR extensions found on the cluster"
  fi
}

collect_aigc_e2e_artifacts() {
  if [[ "$(type -t collect_e2e_artifacts 2>/dev/null)" == "function" ]]; then
    collect_e2e_artifacts || true
  fi
  # Run last so this oc-capable copy wins over the pinned MaaS auth_utils
  # (kubectl-only; silent empty files when kubectl is absent).
  if [[ -f "${_AIGC_SCRIPT_DIR}/collect-e2e-artifacts.sh" ]]; then
    ARTIFACT_DIR="${ARTIFACTS_DIR}" bash "${_AIGC_SCRIPT_DIR}/collect-e2e-artifacts.sh" || true
  fi
  collect_aigc_maas_crs_extensions
  collect_maas_must_gather "$ARTIFACTS_DIR/gather-maas" "$ARTIFACTS_DIR/maas-must-gather.log"
  if [[ "${E2E_COLLECT_MUST_GATHER:-false}" == "true" ]]; then
    collect_must_gather "$ARTIFACTS_DIR/gather-openshift" "$ARTIFACTS_DIR/must-gather.log"
  fi
}
