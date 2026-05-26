#!/usr/bin/env bash
# Flag Service Endpoint Policy (SEP) blocks on a subnet that would prevent
# the agent from reaching Foundry / Storage / AI Search / Cognitive Services
# via service endpoint routing.
#
# Usage:
#   ./check-service-endpoint-policy.sh <subnet_id>
#
# Required role on caller: Reader on the VNet's RG.
#
# Output (machine-readable):
#   SUBNET_ID=<arm_id>
#   SEP_COUNT=<n>
#   SEP_IDS=<comma_separated_or_none>
#   FOUNDRY_AFFECTED=true|false
#   STORAGE_AFFECTED=true|false
#   SEARCH_AFFECTED=true|false
#
# Human-readable verdict on stderr.
#
# Tracked: TD-10 Layer 1 (deep-network).
set -euo pipefail

SUBNET_ID="${1:?usage: $0 <subnet_id>}"

# Subnets carry an array of attached SEP IDs in serviceEndpointPolicies[].
sep_ids_json=$(az network vnet subnet show --ids "$SUBNET_ID" \
  --query "serviceEndpointPolicies[].id" -o json 2>/dev/null || echo "[]")
sep_count=$(echo "$sep_ids_json" | jq 'length')

if [[ "$sep_count" -eq 0 ]]; then
  echo "[i] No Service Endpoint Policies attached to $SUBNET_ID — nothing to check." >&2
  cat <<EOF
SUBNET_ID=$SUBNET_ID
SEP_COUNT=0
SEP_IDS=none
FOUNDRY_AFFECTED=false
STORAGE_AFFECTED=false
SEARCH_AFFECTED=false
EOF
  exit 0
fi

foundry_affected="false"
storage_affected="false"
search_affected="false"

echo "── Service Endpoint Policy check ──" >&2
echo "  Subnet:    $SUBNET_ID" >&2
echo "  SEP count: $sep_count" >&2

# For each attached SEP, enumerate its definitions and check whether any of
# the canonical Foundry-touching service tags are scoped (= effectively allowlisting
# only specific resources of that service, blocking all others).
while IFS= read -r sep_id; do
  [[ -z "$sep_id" || "$sep_id" == "null" ]] && continue
  sep_name=$(basename "$sep_id")
  # api-version pinned to current GA for Microsoft.Network/serviceEndpointPolicies.
  defs=$(az rest --method get \
    --uri "https://management.azure.com${sep_id}?api-version=2025-07-01" \
    --query "properties.serviceEndpointPolicyDefinitions[].{service:service, resources:serviceResources}" \
    -o json 2>/dev/null || echo "[]")
  echo "  ── $sep_name ──" >&2
  while IFS= read -r row; do
    svc=$(echo "$row" | jq -r '.service // ""')
    res_count=$(echo "$row" | jq -r '.resources | length')
    case "$svc" in
      Microsoft.CognitiveServices)
        foundry_affected="true"
        echo "    [⚠] Microsoft.CognitiveServices SEP definition: $res_count allowed resource(s)." >&2
        echo "        Foundry agent calls to accounts NOT in that list will be DENIED." >&2
        ;;
      Microsoft.Storage|Microsoft.Storage.Global)
        storage_affected="true"
        echo "    [⚠] Microsoft.Storage SEP definition: $res_count allowed resource(s)." >&2
        echo "        Blob-via-indexer / knowledge sources outside that list will be DENIED." >&2
        ;;
      Microsoft.Search)
        search_affected="true"
        echo "    [⚠] Microsoft.Search SEP definition: $res_count allowed resource(s)." >&2
        echo "        AI Search calls outside that list will be DENIED." >&2
        ;;
      *)
        echo "    [i] $svc: $res_count allowed resource(s) (not Foundry-relevant)." >&2
        ;;
    esac
  done < <(echo "$defs" | jq -c '.[]')
done < <(echo "$sep_ids_json" | jq -r '.[]')

ids_csv=$(echo "$sep_ids_json" | jq -r 'join(",")')

{
  echo
  if [[ "$foundry_affected" == "true" || "$storage_affected" == "true" || "$search_affected" == "true" ]]; then
    echo "  [✗] One or more SEPs scope Foundry-relevant services. Verify the declared resources"
    echo "      in agent-capabilities.yaml (target.foundry_account, knowledge.sources[]) are listed"
    echo "      in the matching SEP definition; otherwise unscope or extend the SEP."
  else
    echo "  [✓] SEPs present but none affect Foundry / Storage / AI Search."
  fi
} >&2

cat <<EOF
SUBNET_ID=$SUBNET_ID
SEP_COUNT=$sep_count
SEP_IDS=$ids_csv
FOUNDRY_AFFECTED=$foundry_affected
STORAGE_AFFECTED=$storage_affected
SEARCH_AFFECTED=$search_affected
EOF
