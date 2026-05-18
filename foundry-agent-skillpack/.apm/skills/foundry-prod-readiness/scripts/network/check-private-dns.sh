#!/usr/bin/env bash
# Verify that the right private DNS zone for a service is linked to the agent's VNet.
#
# Usage:
#   ./check-private-dns.sh <vnet_resource_id> <service>
#
# <service> is one of: ai_search | storage_blob | storage_dfs | cosmos | keyvault | foundry
# (extend as needed; the mapping table below is the source of truth)
#
# Required role on caller: Reader on the VNet's RG and the private DNS zones.
#
# Output (machine-readable):
#   ZONE_NAME=<expected zone>
#   ZONE_FOUND=true|false
#   ZONE_LINKED_TO_VNET=true|false|<unknown>
#
# Plus a verdict on stderr.
set -euo pipefail

VNET_ID="${1:?usage: $0 <vnet_resource_id> <service>}"
SERVICE="${2:?}"

# Map service to its standard private DNS zone name (region-agnostic — Azure resolves
# regional sub-zones when relevant). When new services are added, update this table.
case "$SERVICE" in
  ai_search)    zone="privatelink.search.windows.net" ;;
  storage_blob) zone="privatelink.blob.core.windows.net" ;;
  storage_dfs)  zone="privatelink.dfs.core.windows.net" ;;
  cosmos)       zone="privatelink.documents.azure.com" ;;
  keyvault)     zone="privatelink.vaultcore.azure.net" ;;
  foundry)      zone="privatelink.cognitiveservices.azure.com" ;;
  *)
    echo "[x] Unknown service: $SERVICE" >&2
    echo "    Supported: ai_search | storage_blob | storage_dfs | cosmos | keyvault | foundry" >&2
    exit 64
    ;;
esac

vnet_sub=$(echo "$VNET_ID"  | awk -F/ '{print $3}')

# Find the zone in the caller's accessible subscriptions.
zone_id=$(az network private-dns zone list --query "[?name=='$zone'].id | [0]" -o tsv 2>/dev/null || true)

if [[ -z "$zone_id" ]]; then
  {
    echo "── DNS check: $SERVICE ──"
    echo "  Expected zone:        $zone"
    echo "  [✗] Not found in any accessible subscription."
    echo "      Create it (or grant Reader to where it lives), then link to VNET:"
    echo "        az network private-dns zone create -g <rg> -n $zone"
    echo "        az network private-dns link vnet create -g <rg> -z $zone -n link-foundry-vnet --virtual-network $VNET_ID --registration-enabled false"
  } >&2
  cat <<EOF
ZONE_NAME=$zone
ZONE_FOUND=false
ZONE_LINKED_TO_VNET=false
EOF
  exit 0
fi

# Check links on the zone for this VNet.
zone_rg=$(echo "$zone_id" | awk -F/ '{for(i=1;i<=NF;i++) if($i=="resourceGroups"){print $(i+1); exit}}')
linked=$(az network private-dns link vnet list \
  -g "$zone_rg" -z "$zone" \
  --query "[?virtualNetwork.id=='$VNET_ID'] | length(@)" \
  -o tsv 2>/dev/null || echo "0")

linked_bool="false"
[[ "$linked" -gt 0 ]] && linked_bool="true"

{
  echo "── DNS check: $SERVICE ──"
  echo "  Expected zone:    $zone"
  echo "  Zone found in:    $zone_rg"
  echo "  Linked to VNET:   $linked_bool"
  if [[ "$linked_bool" == "false" ]]; then
    echo "  [✗] BLOCKER: PE traffic will resolve to public IPs and bypass the private link."
    echo "      Link with:"
    echo "        az network private-dns link vnet create -g $zone_rg -z $zone -n link-foundry-vnet --virtual-network $VNET_ID --registration-enabled false"
  fi
} >&2

cat <<EOF
ZONE_NAME=$zone
ZONE_FOUND=true
ZONE_LINKED_TO_VNET=$linked_bool
EOF
