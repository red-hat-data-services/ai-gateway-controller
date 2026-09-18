#!/usr/bin/env bash
set -Eeuo pipefail

check_boundary() {
  local route=$1 gateway=$2 grants=$3 expected_tenant=$4 expected_gateway_ns=$5 expected_gateway_name=$6 expected_secret_api=$7
  local parent parent_name backend accepted resolved allowed selector secret_api grant_count
  parent=$(jq -r '.spec.parentRefs[0].namespace // .metadata.namespace // ""' "$route")
  parent_name=$(jq -r '.spec.parentRefs[0].name // ""' "$route")
  backend=$(jq -r '.spec.rules[0].backendRefs[0].namespace // .metadata.namespace // ""' "$route")
  accepted=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "Accepted" and .status == "True")] | length' "$route")
  resolved=$(jq -r '[.status.parents[]?.conditions[]? | select(.type == "ResolvedRefs" and .status == "True")] | length' "$route")
  allowed=$(jq -r '.spec.listeners[0].allowedRoutes.namespaces.from // ""' "$gateway")
  selector=$(jq -r '.spec.listeners[0].allowedRoutes.namespaces.selector.matchLabels["local-env.opendatahub.io/gateway-tenant"] // ""' "$gateway")
  secret_api=$expected_secret_api
  grant_count=$(jq '.items | length' "$grants")
  if ! {
    [[ "$parent" == "$expected_gateway_ns" ]] &&
    [[ "$parent_name" == "$expected_gateway_name" ]] &&
    [[ "$backend" == "$expected_tenant" ]] &&
    [[ "$accepted" =~ ^[1-9][0-9]*$ ]] &&
    [[ "$resolved" =~ ^[1-9][0-9]*$ ]] &&
    [[ "$allowed" == Selector ]] &&
    [[ "$selector" == "$expected_tenant" ]] &&
    [[ "$grant_count" == 0 ]] &&
    [[ "$secret_api" == no ]]
  }; then
    return 1
  fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
jq -n '{metadata:{namespace:"tenant-a"},spec:{parentRefs:[{namespace:"maas-system",name:"gateway"}],rules:[{backendRefs:[{name:"praxis"}]}]},status:{parents:[{conditions:[{type:"Accepted",status:"True"},{type:"ResolvedRefs",status:"True"}]}]}}' >"$tmp/valid-route.json"
jq -n --arg tenant tenant-a '{spec:{listeners:[{allowedRoutes:{namespaces:{from:"Selector",selector:{matchLabels:({"local-env.opendatahub.io/gateway-tenant":$tenant})}}}}]}}' >"$tmp/valid-gateway.json"
jq -n '{items:[]}' >"$tmp/no-grants.json"
check_boundary "$tmp/valid-route.json" "$tmp/valid-gateway.json" "$tmp/no-grants.json" tenant-a maas-system gateway no

jq '.spec.parentRefs[0].namespace = "wrong-gateway-ns"' "$tmp/valid-route.json" >"$tmp/wrong-parent.json"
if check_boundary "$tmp/wrong-parent.json" "$tmp/valid-gateway.json" "$tmp/no-grants.json" tenant-a maas-system gateway no; then
  echo 'wrong parent namespace unexpectedly accepted' >&2
  exit 1
fi
jq '.spec.rules[0].backendRefs[0].namespace = "other-tenant"' "$tmp/valid-route.json" >"$tmp/wrong-backend.json"
if check_boundary "$tmp/wrong-backend.json" "$tmp/valid-gateway.json" "$tmp/no-grants.json" tenant-a maas-system gateway no; then
  echo 'cross-namespace backend unexpectedly accepted' >&2
  exit 1
fi

echo 'namespace boundary regression cases passed'
