#!/usr/bin/env bash
# Enumerate Azure Firewall application rules and report whether canonical
# Foundry / source FQDNs are explicitly allowed.
#
# Usage:
#   ./deep-walk-firewall.sh <firewall_id> [<fqdn> ...]
#
# Example:
#   ./deep-walk-firewall.sh \
#     /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/azureFirewalls/<fw> \
#     login.microsoftonline.com \
#     <foundry_account>.services.ai.azure.com
#
# Required role on caller: Reader on the Firewall.
#
# Output (machine-readable):
#   FIREWALL_ID=<arm_id>
#   FIREWALL_NAME=<name>
#   POLICY_ID=<arm_id_or_none>
#   APP_RULE_COLLECTION_COUNT=<n>
#   MISSING_FQDN_COUNT=<n>
#   MISSING_FQDNS=<comma_separated>
#
# Human-readable verdict on stderr.
#
# Tracked: TD-10 Layer 1 (deep-network).
set -euo pipefail

FW_ID="${1:?usage: $0 <firewall_id> [<fqdn> ...]}"
shift || true
FQDNS=("$@")

fw_name=$(basename "$FW_ID")

# Azure Firewall application rules live in two places:
#   (1) classic — under the firewall resource itself (applicationRuleCollections)
#   (2) policy-based — under an attached Firewall Policy (preferred since 2020)
# We try both.

classic_json=$(az network firewall application-rule collection list --ids "$FW_ID" -o json 2>/dev/null || echo "[]")
classic_count=$(echo "$classic_json" | jq 'length')

policy_id=$(az network firewall show --ids "$FW_ID" --query "firewallPolicy.id" -o tsv 2>/dev/null || echo "")
policy_rules_json="[]"
policy_count=0
if [[ -n "$policy_id" && "$policy_id" != "null" ]]; then
  # Enumerate all rule collection groups → collections → rules of type ApplicationRule.
  # api-version pinned to current GA for Microsoft.Network/firewallPolicies/ruleCollectionGroups.
  groups=$(az rest --method get \
    --uri "https://management.azure.com${policy_id}/ruleCollectionGroups?api-version=2025-09-01" \
    -o json 2>/dev/null || echo '{"value":[]}')
  policy_rules_json=$(echo "$groups" | jq '[.value[].properties.ruleCollections[]?.rules[]? | select(.ruleType=="ApplicationRule")]')
  policy_count=$(echo "$policy_rules_json" | jq 'length')
fi

total_collections=$((classic_count + (policy_count > 0 ? 1 : 0)))

# Collect every allowed FQDN (target FQDN OR FQDN tag match) across both surfaces.
allowed_fqdns=$( {
  echo "$classic_json" | jq -r '.[]?.rules[]?.targetFqdns[]?'
  echo "$classic_json" | jq -r '.[]?.rules[]?.fqdnTags[]? | "TAG:" + .'
  echo "$policy_rules_json" | jq -r '.[]?.targetFqdns[]?'
  echo "$policy_rules_json" | jq -r '.[]?.fqdnTags[]? | "TAG:" + .'
} | sort -u)

missing=()
for need in "${FQDNS[@]}"; do
  hit="no"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Exact match
    if [[ "$entry" == "$need" ]]; then hit="yes"; break; fi
    # Wildcard match (entry has leading * meaning subdomain wildcard)
    if [[ "$entry" == \** ]]; then
      suffix="${entry#\*}"
      [[ "$need" == *"$suffix" ]] && { hit="yes"; break; }
    fi
    # FQDN tag (e.g., AzureActiveDirectory) — we can't resolve tag→FQDN list
    # cheaply; print a hint instead of false-positive.
    if [[ "$entry" == TAG:* ]]; then
      echo "  [i] $need MAY be covered by FQDN tag '${entry#TAG:}' — verify manually." >&2
    fi
  done <<< "$allowed_fqdns"
  [[ "$hit" == "no" ]] && missing+=("$need")
done

{
  echo "── Azure Firewall walk: $fw_name ──"
  echo "  Classic application rule collections: $classic_count"
  echo "  Policy-based application rules:       $policy_count"
  if [[ ${#FQDNS[@]} -eq 0 ]]; then
    echo "  [i] No FQDNs provided to check. Pass canonical FQDNs as additional arguments."
  elif [[ ${#missing[@]} -eq 0 ]]; then
    echo "  [✓] All ${#FQDNS[@]} canonical FQDNs are explicitly allowed."
  else
    echo "  [✗] ${#missing[@]} of ${#FQDNS[@]} canonical FQDNs are NOT in any application rule:"
    for f in "${missing[@]}"; do echo "        - $f"; done
    echo "      Either add an Allow rule with these targetFqdns, or use an FQDN tag that covers them."
    echo "      Reference: foundry-prod-readiness/networking.md § Firewall allowlist."
  fi
} >&2

missing_csv=$(IFS=, ; echo "${missing[*]:-}")
cat <<EOF
FIREWALL_ID=$FW_ID
FIREWALL_NAME=$fw_name
POLICY_ID=${policy_id:-none}
APP_RULE_COLLECTION_COUNT=$total_collections
MISSING_FQDN_COUNT=${#missing[@]}
MISSING_FQDNS=$missing_csv
EOF
