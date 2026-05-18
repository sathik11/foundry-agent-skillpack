#!/usr/bin/env bash
# Walk effective NSG rules on a subnet and check outbound 443 against canonical
# Foundry / source FQDNs.
#
# Usage:
#   ./deep-walk-nsg.sh <subnet_id> [<extra_fqdn> ...]
#
# Example:
#   ./deep-walk-nsg.sh \
#     /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet> \
#     <foundry_account>.services.ai.azure.com \
#     <search>.search.windows.net
#
# Required role on caller: Reader on the VNet's RG.
#
# Output (machine-readable):
#   NSG_ID=<arm_id_or_none>
#   NSG_NAME=<name_or_none>
#   DECLARED_RULE_COUNT=<n>
#   OUTBOUND_443_VERDICT=allow|deny|unknown
#   EFFECTIVE_RULES_AVAILABLE=true|false
#
# Human-readable verdict + per-rule trace on stderr.
#
# Tracked: TD-10 Layer 1 (deep-network).
set -euo pipefail

SUBNET_ID="${1:?usage: $0 <subnet_id> [<extra_fqdn> ...]}"
shift || true
EXTRA_FQDNS=("$@")

# Lookup the NSG attached to the subnet
nsg_id=$(az network vnet subnet show --ids "$SUBNET_ID" \
  --query "networkSecurityGroup.id" -o tsv 2>/dev/null || echo "")

if [[ -z "$nsg_id" || "$nsg_id" == "null" ]]; then
  echo "[i] No NSG attached to subnet $SUBNET_ID — nothing to walk." >&2
  cat <<EOF
NSG_ID=none
NSG_NAME=none
DECLARED_RULE_COUNT=0
OUTBOUND_443_VERDICT=allow
EFFECTIVE_RULES_AVAILABLE=false
EOF
  exit 0
fi

nsg_name=$(basename "$nsg_id")

# Declared rules — always available with Reader
declared=$(az network nsg rule list --ids "$nsg_id" -o json 2>/dev/null || echo "[]")
rule_count=$(echo "$declared" | jq 'length')

# Heuristic: is outbound 443 to internet (or any service tag) blocked?
# Walk rules in priority order (lower number = higher priority); first match wins.
verdict="allow"  # NSG default-allow for outbound to internet
matched_rule=""
while IFS= read -r row; do
  direction=$(echo  "$row" | jq -r '.direction // ""')
  access=$(echo     "$row" | jq -r '.access // ""')
  proto=$(echo      "$row" | jq -r '.protocol // "*"')
  dest_port=$(echo  "$row" | jq -r '.destinationPortRange // (.destinationPortRanges // [""] | join(","))')
  dest_pref=$(echo  "$row" | jq -r '.destinationAddressPrefix // (.destinationAddressPrefixes // [""] | join(","))')
  name=$(echo       "$row" | jq -r '.name // ""')

  [[ "$direction" != "Outbound" ]] && continue
  [[ "$proto" != "Tcp" && "$proto" != "*" ]] && continue
  # port range matches 443?
  case "$dest_port" in
    443|"*"|"0-65535"|*"443"*) ;;
    *) continue ;;
  esac
  # destination is internet / any?
  case "$dest_pref" in
    "*"|"0.0.0.0/0"|"Internet"|"AzureCloud"*|"") ;;
    *) continue ;;
  esac
  matched_rule="$name (access=$access, ports=$dest_port, prefix=$dest_pref)"
  if [[ "$access" == "Deny" ]]; then verdict="deny"; else verdict="allow"; fi
  break
done < <(echo "$declared" | jq -c 'sort_by(.priority)[]')

# Try effective rules — works only if at least one NIC sits in the subnet
eff_available="false"
nic_id=$(az network nic list --query \
  "[?ipConfigurations[?subnet.id=='$SUBNET_ID']]|[0].id" -o tsv 2>/dev/null || echo "")
if [[ -n "$nic_id" && "$nic_id" != "null" ]]; then
  eff_available="true"
  eff=$(az network nic list-effective-network-security-rules --ids "$nic_id" -o json 2>/dev/null || echo "[]")
  eff_deny=$(echo "$eff" | jq -r '[.[] | select(.direction=="Outbound" and .access=="Deny")] | length')
  if [[ "$eff_deny" -gt 0 && "$verdict" == "allow" ]]; then
    verdict="deny"
    matched_rule="effective_outbound_deny_count=$eff_deny (see az network nic list-effective-network-security-rules --ids $nic_id)"
  fi
fi

{
  echo "── NSG walk: $nsg_name ──"
  echo "  Subnet:                    $SUBNET_ID"
  echo "  Declared rule count:       $rule_count"
  echo "  Effective rules available: $eff_available (delegated subnets often have no enumerable NIC)"
  echo "  Outbound 443 verdict:      $verdict"
  [[ -n "$matched_rule" ]] && echo "  Matching rule:             $matched_rule"
  if [[ "$verdict" == "deny" ]]; then
    echo
    echo "  [✗] Outbound TCP/443 is blocked by NSG. The agent will fail to reach Foundry / data sources."
    echo "      Add an explicit Allow rule for outbound 443 to the required service tags or FQDNs:"
    for fqdn in "${EXTRA_FQDNS[@]}"; do echo "        - $fqdn"; done
    echo "      Reference: foundry-prod-readiness/networking.md § Firewall allowlist."
  elif [[ ${#EXTRA_FQDNS[@]} -gt 0 ]]; then
    echo
    echo "  [i] NSG does not block outbound 443. FQDN-level restriction requires Azure Firewall +"
    echo "      'Allow only approved outbound' on Foundry. Run deep-walk-firewall.sh if a Firewall is"
    echo "      in the route path. Declared canonical FQDNs to allowlist:"
    for fqdn in "${EXTRA_FQDNS[@]}"; do echo "        - $fqdn"; done
  fi
} >&2

cat <<EOF
NSG_ID=$nsg_id
NSG_NAME=$nsg_name
DECLARED_RULE_COUNT=$rule_count
OUTBOUND_443_VERDICT=$verdict
EFFECTIVE_RULES_AVAILABLE=$eff_available
EOF
