#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export GET_MANIFESTS_TEST_ONLY=true
# shellcheck disable=SC1091
source "$SCRIPT_DIR/get-manifests.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

write_role() {
    local path=$1 rules=$2
    yq -n ".apiVersion = \"rbac.authorization.k8s.io/v1\" | .kind = \"ClusterRole\" | .metadata.name = \"test\" | .rules = ${rules}" >"$path"
}

assert_unchanged_and_succeeds() {
    local path=$1 before after
    before=$(sha256sum "$path")
    normalize_extproc_cluster_role "$path"
    after=$(sha256sum "$path")
    [[ "$before" == "$after" ]] || { echo "already-normalized manifest changed: $path" >&2; exit 1; }
}

assert_fails_closed() {
    local path=$1 before after
    before=$(sha256sum "$path")
    if (normalize_extproc_cluster_role "$path"); then
        echo "expected normalization failure: $path" >&2
        exit 1
    fi
    after=$(sha256sum "$path")
    [[ "$before" == "$after" ]] || { echo "failed normalization modified: $path" >&2; exit 1; }
}

# Upstream is already Secret-free: the script must succeed without rewriting
# or reformatting the vendored file.
write_role "$tmp/secret-free.yaml" '[{"apiGroups":[""],"resources":["configmaps"],"verbs":["get"]}]'
assert_unchanged_and_succeeds "$tmp/secret-free.yaml"

# Exactly one expected rule is the legacy input that must be removed.
write_role "$tmp/one-expected.yaml" '[{"apiGroups":[""],"resources":["secrets"],"verbs":["get"]},{"apiGroups":[""],"resources":["configmaps"],"verbs":["get"]}]'
normalize_extproc_cluster_role "$tmp/one-expected.yaml"
[[ "$(yq eval '[.rules[]? | select(((.resources // []) | contains(["secrets"])) or ((.resources // []) | contains(["*"])))] | length' "$tmp/one-expected.yaml")" == 0 ]] || exit 1

# An unexpected Secret rule must fail closed and leave the source intact.
write_role "$tmp/unexpected-secret.yaml" '[{"apiGroups":["apps"],"resources":["secrets"],"verbs":["get"]}]'
assert_fails_closed "$tmp/unexpected-secret.yaml"

# A residual Secret permission after removing the expected rule must also fail
# closed rather than publishing a partially-normalized role.
write_role "$tmp/residual-secret.yaml" '[{"apiGroups":[""],"resources":["secrets"],"verbs":["get"]},{"apiGroups":[""],"resources":["secrets"],"verbs":["list"]}]'
assert_fails_closed "$tmp/residual-secret.yaml"

# Duplicate expected rules must fail closed rather than deleting both.
write_role "$tmp/duplicate-expected.yaml" '[{"apiGroups":[""],"resources":["secrets"],"verbs":["get"]},{"apiGroups":[""],"resources":["secrets"],"verbs":["get"]}]'
assert_fails_closed "$tmp/duplicate-expected.yaml"

echo 'get-manifests RBAC regression cases: PASS'
