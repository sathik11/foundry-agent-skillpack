#!/usr/bin/env bash
# Detect a source resource's network posture.
#
# Usage:
#   ./check-source-network.sh <full_resource_id> [--deep <agent_subnet_id> [<firewall_id>] [<fqdn> ...]]
#
# Examples:
#   ./check-source-network.sh /subscriptions/.../Microsoft.Search/searchServices/kb-prod
#   ./check-source-network.sh /subscriptions/.../Microsoft.Storage/storageAccounts/raw
#   ./check-source-network.sh /subscriptions/.../Microsoft.DocumentDB/databaseAccounts/cosmos-prod
#
# --deep mode (TD-10 Layer 1) opts into NSG / Firewall / Service Endpoint Policy
# walks on the agent's delegated subnet. Slow path (60-120s typical). Cascades
# additional FQDNs into deep-walk-firewall.sh so the canonical Foundry / source
# FQDNs are verified against application rule collections.
#
# Required role on caller: Reader on the resource (and on the VNet / Firewall in
# --deep mode).
#
# Output (machine-readable):
#   RESOURCE_KIND=<short>           # ai_search|storage|cosmos|keyvault|fabric|other
#   PUBLIC_NETWORK_ACCESS=Enabled|Disabled|SecuredByPerimeter|<unknown>
#   ACL_DEFAULT_ACTION=Allow|Deny|<unknown>
#   IP_RULE_COUNT=<n>
#   VNET_RULE_COUNT=<n>
#   PE_COUNT=<n>
#   DEEP_NSG_VERDICT=allow|deny|skipped
#   DEEP_FIREWALL_MISSING_FQDNS=<csv_or_skipped>
#   DEEP_SEP_FOUNDRY_AFFECTED=true|false|skipped
#
# Plus a verdict on stderr.
set -euo pipefail

RID="${1:?usage: $0 <full_resource_id> [--deep <agent_subnet_id> [<firewall_id>] [<fqdn> ...]]}"
shift || true

DEEP="false"
AGENT_SUBNET=""
FIREWALL_ID=""
DEEP_FQDNS=()
if [[ "${1:-}" == "--deep" ]]; then
  DEEP="true"
  shift
  AGENT_SUBNET="${1:?--deep requires <agent_subnet_id>}"
  shift
  # Optional next positional: firewall_id (if it starts with /subscriptions/ and
  # contains 'azureFirewalls'); otherwise treat everything else as FQDNs.
  if [[ "${1:-}" == *"/azureFirewalls/"* ]]; then
    FIREWALL_ID="$1"
    shift
  fi
  DEEP_FQDNS=("$@")
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Identify resource type to know what query to run.
provider=$(echo "$RID" | awk -F/ '{for(i=1;i<=NF;i++) if($i=="providers"){print $(i+1)"/"$(i+2); exit}}')
case "$provider" in
  Microsoft.Search/searchServices)         kind="ai_search";   apiv="2024-06-01-preview" ;;
  Microsoft.Storage/storageAccounts)       kind="storage";     apiv="2023-05-01" ;;
  Microsoft.DocumentDB/databaseAccounts)   kind="cosmos";      apiv="2024-05-15" ;;
  Microsoft.KeyVault/vaults)               kind="keyvault";    apiv="2024-04-01-preview" ;;
  Microsoft.Fabric/capacities)             kind="fabric";      apiv="2023-11-01" ;;
  Microsoft.CognitiveServices/accounts)    kind="cogsvc";      apiv="2025-04-01-preview" ;;
  *)                                       kind="other";       apiv="2024-04-01" ;;
esac

resp=$(az rest --method get \
  --uri "https://management.azure.com$RID?api-version=$apiv" \
  -o json 2>/dev/null) || {
    echo "[!] No Reader on $RID (or resource doesn't exist)" >&2
    cat <<EOF
RESOURCE_KIND=$kind
PUBLIC_NETWORK_ACCESS=<unknown>
ACL_DEFAULT_ACTION=<unknown>
IP_RULE_COUNT=0
VNET_RULE_COUNT=0
PE_COUNT=0
DEEP_NSG_VERDICT=skipped
DEEP_FIREWALL_MISSING_FQDNS=skipped
DEEP_SEP_FOUNDRY_AFFECTED=skipped
EOF
    exit 2
}

pna=$(echo "$resp" | jq -r '.properties.publicNetworkAccess // "Enabled"')

# Network ACLs live in different places per service.
case "$kind" in
  ai_search)
    default_action="Allow"
    if [[ "$(echo "$resp" | jq -r '.properties.networkRuleSet.bypass // ""')" == "AzureServices" ]]; then default_action="Allow"; fi
    if [[ "$(echo "$resp" | jq -r '.properties.networkRuleSet.ipRules | length')" -gt 0 ]]; then default_action="Deny"; fi
    ip_count=$(echo   "$resp" | jq -r '.properties.networkRuleSet.ipRules | length')
    vnet_count=0
    ;;
  storage)
    default_action=$(echo "$resp" | jq -r '.properties.networkAcls.defaultAction // "Allow"')
    ip_count=$(echo       "$resp" | jq -r '.properties.networkAcls.ipRules | length')
    vnet_count=$(echo     "$resp" | jq -r '.properties.networkAcls.virtualNetworkRules | length')
    ;;
  cosmos)
    default_action="Allow"
    if [[ "$(echo "$resp" | jq -r '.properties.isVirtualNetworkFilterEnabled // false')" == "true" ]]; then default_action="Deny"; fi
    ip_count=$(echo  "$resp" | jq -r '.properties.ipRules | length')
    vnet_count=$(echo "$resp" | jq -r '.properties.virtualNetworkRules | length')
    ;;
  keyvault)
    default_action=$(echo "$resp" | jq -r '.properties.networkAcls.defaultAction // "Allow"')
    ip_count=$(echo       "$resp" | jq -r '.properties.networkAcls.ipRules | length')
    vnet_count=$(echo     "$resp" | jq -r '.properties.networkAcls.virtualNetworkRules | length')
    ;;
  fabric)
    default_action="<n/a>"
    ip_count=0
    vnet_count=0
    ;;
  *)
    default_action="<unknown>"
    ip_count=0
    vnet_count=0
    ;;
esac

pe_count=$(echo "$resp" | jq -r '.properties.privateEndpointConnections | length // 0')

# Verdict
{
  echo "── Source network: $kind @ $(basename "$RID") ──"
  echo "  publicNetworkAccess: $pna"
  echo "  defaultAction:       $default_action"
  echo "  ipRules:             $ip_count"
  echo "  vnetRules:           $vnet_count"
  echo "  privateEndpoints:    $pe_count"
  echo
  if [[ "$pna" == "Disabled" && "$pe_count" -eq 0 ]]; then
    echo "  [✗] BLOCKER: public access is Disabled and there are no private endpoints. Resource is unreachable from any agent."
  elif [[ "$pna" == "Disabled" ]]; then
    echo "  [⚠] Public access Disabled — only reachable via PE. Verify Foundry's network class can reach it (see check-private-endpoint.sh)."
  elif [[ "$default_action" == "Deny" && "$ip_count" -gt 0 ]]; then
    echo "  [⚠] Default-Deny with IP allowlist — Foundry hosted agent egress IPs are dynamic; allowlist will silently 403."
  elif [[ "$default_action" == "Deny" && "$vnet_count" -eq 0 && "$pe_count" -eq 0 ]]; then
    echo "  [✗] BLOCKER: Default-Deny with no PE and no VNet rule. Nothing can reach this resource."
  else
    echo "  [✓] Reachable from public Foundry agent."
  fi
  if [[ "$kind" == "fabric" ]]; then
    echo "  [⚠] Fabric Data Agent path is NOT supported in network-isolated agents — Fabric workspace must remain public."
  fi
} >&2

cat <<EOF
RESOURCE_KIND=$kind
PUBLIC_NETWORK_ACCESS=$pna
ACL_DEFAULT_ACTION=$default_action
IP_RULE_COUNT=$ip_count
VNET_RULE_COUNT=$vnet_count
PE_COUNT=$pe_count
EOF

# ── --deep mode: cascade to NSG / Firewall / SEP walkers ─────────────────
deep_nsg="skipped"
deep_fw_missing="skipped"
deep_sep="skipped"
if [[ "$DEEP" == "true" ]]; then
  echo >&2
  echo "── Deep walk on agent subnet: $AGENT_SUBNET ──" >&2
  # NSG
  if [[ -x "$SCRIPT_DIR/deep-walk-nsg.sh" ]]; then
    nsg_out=$("$SCRIPT_DIR/deep-walk-nsg.sh" "$AGENT_SUBNET" "${DEEP_FQDNS[@]}" 2>&1 1>/tmp/.dwnsg.$$ || true)
    echo "$nsg_out" >&2
    deep_nsg=$(grep '^OUTBOUND_443_VERDICT=' /tmp/.dwnsg.$$ | cut -d= -f2- || echo "unknown")
    rm -f /tmp/.dwnsg.$$
  fi
  # SEP
  if [[ -x "$SCRIPT_DIR/check-service-endpoint-policy.sh" ]]; then
    sep_out=$("$SCRIPT_DIR/check-service-endpoint-policy.sh" "$AGENT_SUBNET" 2>&1 1>/tmp/.dwsep.$$ || true)
    echo "$sep_out" >&2
    deep_sep=$(grep '^FOUNDRY_AFFECTED=' /tmp/.dwsep.$$ | cut -d= -f2- || echo "false")
    rm -f /tmp/.dwsep.$$
  fi
  # Firewall
  if [[ -n "$FIREWALL_ID" && -x "$SCRIPT_DIR/deep-walk-firewall.sh" ]]; then
    fw_out=$("$SCRIPT_DIR/deep-walk-firewall.sh" "$FIREWALL_ID" "${DEEP_FQDNS[@]}" 2>&1 1>/tmp/.dwfw.$$ || true)
    echo "$fw_out" >&2
    deep_fw_missing=$(grep '^MISSING_FQDNS=' /tmp/.dwfw.$$ | cut -d= -f2- || echo "")
    rm -f /tmp/.dwfw.$$
  elif [[ -z "$FIREWALL_ID" ]]; then
    echo "  [i] No firewall_id provided — skipping Azure Firewall walk. Pass it after the" >&2
    echo "      agent_subnet_id if a Firewall sits in the route path." >&2
  fi
fi

cat <<EOF
DEEP_NSG_VERDICT=$deep_nsg
DEEP_FIREWALL_MISSING_FQDNS=$deep_fw_missing
DEEP_SEP_FOUNDRY_AFFECTED=$deep_sep
EOF

# ── BYO VNet hand-off: paste-ready Bicep snippet (TD-10 Layer 2) ────────
# Emit the snippet pointer only when this resource is unreachable from a public
# Foundry agent AND no PE exists. The user almost certainly needs to provision
# a BYO VNet + PE; we hand off a paste-ready artifact rather than running
# `az network create` ourselves (deploy boundary).
if [[ "$pna" == "Disabled" && "$pe_count" -eq 0 ]]; then
  snippet="$SCRIPT_DIR/templates/byo-vnet-with-pe.bicep"
  if [[ -f "$snippet" ]]; then
    {
      echo
      echo "── Hand-off ──"
      echo "  [i] $(basename "$RID") is unreachable from a public Foundry agent."
      echo "      Drop the known-good BYO VNet + PE scaffold into ./infra/ and re-run azd up:"
      echo "        $snippet"
      echo "      Then re-run /prepare-deploy. See foundry-prod-readiness/network-troubleshooter.md."
    } >&2
  fi
fi
