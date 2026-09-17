#!/usr/bin/env bash
set -euo pipefail

# Vendors the praxis-extproc ODH kustomize overlay at a pinned commit into
# config/manifests/praxis-extproc/.
#
# To upgrade: change PRAXIS_EXTPROC_COMMIT below and run "make get-manifests".

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

PRAXIS_EXTPROC_REPO="https://github.com/opendatahub-io/praxis-extproc"
PRAXIS_EXTPROC_COMMIT="d030ea0b2e4d775df4c7485652a48198d1a364ec"

# The "odh" overlay references "../../base/..." paths that resolve relative to
# deploy/, so we vendor deploy/base and deploy/overlays/odh together, preserving
# their relative layout (minus the "deploy/" prefix) so those references still
# resolve. The kustomize entrypoint after vendoring is
# config/manifests/praxis-extproc/overlays/odh.
DST_ROOT="${PROJECT_ROOT}/config/manifests/praxis-extproc"

fetch_praxis_extproc() {
    # Always wipe the destination before copy so stale files from a previous
    # pin never linger.
    if [[ "${USE_LOCAL:-}" == "true" ]] && [[ -d "${PROJECT_ROOT}/../praxis-extproc" ]]; then
        echo "Copying manifests from adjacent praxis-extproc checkout"
        rm -rf "${DST_ROOT}"
        mkdir -p "${DST_ROOT}/base" "${DST_ROOT}/overlays/odh"
        cp -a "${PROJECT_ROOT}/../praxis-extproc/deploy/base/." "${DST_ROOT}/base/"
        cp -a "${PROJECT_ROOT}/../praxis-extproc/deploy/overlays/odh/." "${DST_ROOT}/overlays/odh/"
        echo "Manifests copied to ${DST_ROOT}"
        return
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d -t "praxis-extproc-manifests.XXXXXXXXXX")

    git -C "${tmp_dir}" init -q
    git -C "${tmp_dir}" remote add origin "${PRAXIS_EXTPROC_REPO}"
    git -C "${tmp_dir}" fetch --depth 1 -q origin "${PRAXIS_EXTPROC_COMMIT}"
    git -C "${tmp_dir}" reset -q --hard "${PRAXIS_EXTPROC_COMMIT}"

    rm -rf "${DST_ROOT}"
    mkdir -p "${DST_ROOT}/base" "${DST_ROOT}/overlays/odh"
    cp -a "${tmp_dir}/deploy/base/." "${DST_ROOT}/base/"
    cp -a "${tmp_dir}/deploy/overlays/odh/." "${DST_ROOT}/overlays/odh/"

    rm -rf "${tmp_dir}"

    echo "[praxis-extproc] Manifests ready at ${DST_ROOT} (commit ${PRAXIS_EXTPROC_COMMIT})"
}

fetch_praxis_extproc
