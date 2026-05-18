#!/usr/bin/env bash
# List private endpoints on a resource and their approval state.
#
# Usage:
#   ./check-private-endpoint.sh <full_resource_id>
#
# Required role on caller: Reader on the resource.
#
# Output (machine-readable, one line per PE):
#   PE_NAME=<name> PE_STATUS=Approved|Pending|Rejected|Disconnected PE_OWNER=<connector_subscription>
#
# Plus a summary verdict on stderr.
set -euo pipefail

RID="${1:?usage: $0 <full_resource_id>}"

provider=$(echo "$RID" | awk -F/ '{for(i=1;i<=NF;i++) if($i=="providers"){print $(i+1)"/"$(i+2); exit}}')
case "$provider" in
  Microsoft.Search/searchServices)       apiv="2024-06-01-preview" ;;
  Microsoft.Storage/storageAccounts)     apiv="2023-05-01" ;;
  Microsoft.DocumentDB/databaseAccounts) apiv="2024-05-15" ;;
  Microsoft.KeyVault/vaults)             apiv="2024-04-01-preview" ;;
  Microsoft.CognitiveServices/accounts)  apiv="2025-04-01-preview" ;;
  *)                                     apiv="2024-04-01" ;;
esac

# Generic listPrivateEndpointConnections — most resource types use the same shape.
resp=$(az rest --method get \
  --uri "https://management.azure.com$RID/privateEndpointConnections?api-version=$apiv" \
  -o json 2>/dev/null) || {
    echo "[!] No Reader on $RID, or resource doesn't expose privateEndpointConnections" >&2
    exit 2
}

count=$(echo "$resp" | jq '.value | length')

if (( count == 0 )); then
  {
    echo "── PE check: $(basename "$RID") ──"
    echo "  No private endpoints on this resource."
  } >&2
  exit 0
fi

approved=0; pending=0; rejected=0; disconnected=0
echo "$resp" | jq -r '.value[] | [.name, .properties.privateLinkServiceConnectionState.status, .properties.privateEndpoint.id] | @tsv' \
  | while IFS=$'\t' read -r name status pe_id; do
    case "$status" in
      Approved)     approved=$((approved+1)) ;;
      Pending)      pending=$((pending+1)) ;;
      Rejected)     rejected=$((rejected+1)) ;;
      Disconnected) disconnected=$((disconnected+1)) ;;
    esac
    pe_sub=$(echo "$pe_id" | awk -F/ '{print $3}')
    echo "PE_NAME=$name PE_STATUS=$status PE_OWNER=$pe_sub"
  done

# Note: counts above are scoped to the subshell; recompute for the verdict.
approved=$(echo "$resp" | jq '[.value[] | select(.properties.privateLinkServiceConnectionState.status=="Approved")] | length')
pending=$( echo "$resp" | jq '[.value[] | select(.properties.privateLinkServiceConnectionState.status=="Pending")] | length')
rejected=$(echo "$resp" | jq '[.value[] | select(.properties.privateLinkServiceConnectionState.status=="Rejected")] | length')

{
  echo "── PE check: $(basename "$RID") ──"
  echo "  Total: $count   Approved: $approved   Pending: $pending   Rejected: $rejected"
  if (( pending > 0 )); then
    echo "  [⚠] $pending PE connection(s) Pending. Approve via:"
    echo "      Azure Portal → resource → Networking → Private endpoint connections → Approve"
    echo "      Required role: Contributor or Owner on the resource (per side)."
  fi
  if (( rejected > 0 )); then
    echo "  [✗] $rejected PE connection(s) Rejected. Investigate before relying on PE for connectivity."
  fi
} >&2
