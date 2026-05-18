#!/usr/bin/env bash
# Detect Foundry account's network class + ACR public-access flag.
#
# Usage:
#   ./check-foundry-network-mode.sh <subscription_id> <rg> <foundry_account> [<acr_name>]
#
# Required role on caller: Reader on the Foundry account (and ACR if provided).
#
# Output (machine-readable, eval-friendly):
#   FOUNDRY_NETWORK_CLASS=public|managed_vnet|byo_vnet|unknown
#   FOUNDRY_PNA=Enabled|Disabled|<unknown>
#   FOUNDRY_OUTBOUND_MODE=internet|approved_only|disabled|<unknown>
#   FOUNDRY_REGION=<region>
#   ACR_PNA=Enabled|Disabled|<n/a>
#
# Plus a human-readable verdict on stderr.
set -euo pipefail

SUB="${1:?usage: $0 <sub> <rg> <foundry_account> [<acr_name>]}"
RG="${2:?}"
ACCOUNT="${3:?}"
ACR="${4:-}"

API_VERSION="2025-04-01-preview"

acct_json=$(az rest --method get \
  --uri "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACCOUNT?api-version=$API_VERSION" \
  -o json 2>/dev/null) || {
    echo "[!] No Reader on Foundry account '$ACCOUNT' in '$RG' (or account doesn't exist)" >&2
    cat <<EOF
FOUNDRY_NETWORK_CLASS=unknown
FOUNDRY_PNA=<unknown>
FOUNDRY_OUTBOUND_MODE=<unknown>
FOUNDRY_REGION=<unknown>
ACR_PNA=<n/a>
EOF
    exit 2
}

pna=$(echo "$acct_json"     | jq -r '.properties.publicNetworkAccess // "Enabled"')
region=$(echo "$acct_json"  | jq -r '.location // "unknown"')
isolation=$(echo "$acct_json" | jq -r '.properties.networkInjections // .properties.networkAcls.virtualNetworkRules // [] | length')
managed_mv=$(echo "$acct_json" | jq -r '.properties.networkAcls.bypass // empty')
managed_outbound=$(echo "$acct_json" | jq -r '.properties.networkOutboundConfiguration.outboundType // .properties.managedNetworkSettings.isolationMode // empty')

# Network class heuristic
class="public"
if [[ -n "$managed_outbound" && "$managed_outbound" != "null" && "$managed_outbound" != "Disabled" ]]; then
  class="managed_vnet"
fi
if [[ "$isolation" -gt 0 ]]; then
  class="byo_vnet"
fi

# Map outbound mode to canonical value
outbound="internet"
case "$managed_outbound" in
  AllowInternetOutbound|AllowAllOutbound)  outbound="internet" ;;
  AllowOnlyApprovedOutbound)               outbound="approved_only" ;;
  Disabled|"")                             outbound="disabled" ;;
  *)                                       outbound="$managed_outbound" ;;
esac

# ACR check (the silent killer for hosted agents)
acr_pna="<n/a>"
if [[ -n "$ACR" ]]; then
  acr_pna=$(az acr show -n "$ACR" -g "$RG" --query "publicNetworkAccess" -o tsv 2>/dev/null || echo "<unknown>")
fi

# Human-readable verdict
{
  echo "── Foundry network class: $class ──"
  echo "  Region:            $region"
  echo "  Inbound PNA:       $pna"
  echo "  Outbound mode:     $outbound"
  if [[ -n "$ACR" ]]; then
    echo "  ACR public access: $acr_pna"
    if [[ "$class" != "public" && "$acr_pna" == "Disabled" ]]; then
      echo
      echo "  [✗] BLOCKER: ACR public access is Disabled, but Foundry hosted agents currently"
      echo "      require ACR with public network access ENABLED — even when Foundry itself"
      echo "      is on a managed/BYO VNet. See:"
      echo "      https://learn.microsoft.com/azure/foundry/how-to/configure-private-link#limitations-and-considerations"
    fi
  fi
} >&2

cat <<EOF
FOUNDRY_NETWORK_CLASS=$class
FOUNDRY_PNA=$pna
FOUNDRY_OUTBOUND_MODE=$outbound
FOUNDRY_REGION=$region
ACR_PNA=$acr_pna
EOF
