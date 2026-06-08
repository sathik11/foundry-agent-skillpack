#!/usr/bin/env bash
# Apply Phase 1 (AcrPull) + Phase 2 (5 runtime roles) for a Foundry hosted agent.
# Phase 3 (data-access) is capability-driven — handled by the matching skill's script:
#   foundry-guardrails/scripts/grant-cs-access.sh
#   foundry-fabric (print-only today — TD-1)
#
# Usage:
#   ./grant-rbac.sh <subscription_id> <rg> <foundry_account> <project> <acr_name> <agent_name>
set -euo pipefail

SUB="${1:?usage: $0 <sub> <rg> <account> <project> <acr> <agent>}"
RG="${2:?}"
ACCOUNT="${3:?}"
PROJECT="${4:?}"
ACR="${5:?}"
AGENT="${6:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Discover identities
eval "$("$SCRIPT_DIR/check-identities.sh" "$SUB" "$RG" "$ACCOUNT" "$PROJECT" "$AGENT")"

if [[ -z "$AGENT_PRINCIPAL" ]]; then
  echo "[x] Agent identity not yet created. Run 'azd up' first." >&2
  exit 1
fi

ACCOUNT_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACCOUNT"
PROJECT_ID="$ACCOUNT_ID/projects/$PROJECT"
ACR_ID=$(az acr show -n "$ACR" -g "$RG" --query id -o tsv)

grant() {
  local principal="$1" role="$2" scope="$3"
  # `role` may be a role name OR a role-definition GUID. We prefer GUIDs for the
  # four Foundry data-plane roles during the rename rollout (TD-30) — Microsoft
  # Learn explicitly recommends "use the role definition ID (GUID) instead of
  # the role name in your code to avoid issues during the rename rollout".
  echo "  - $role @ $(basename "$scope")"
  az role assignment create \
    --assignee-object-id "$principal" \
    --assignee-principal-type ServicePrincipal \
    --role "$role" \
    --scope "$scope" \
    --only-show-errors >/dev/null || echo "    (may already exist — continuing)"
}

# Foundry data-plane role definition IDs (TD-30). Stable across the rename.
ROLE_FOUNDRY_USER="53ca6127-db72-4b80-b1b0-d745d6d5456d"  # was: Azure AI User

echo "[+] Phase 1 — Image pull (Project MI)"
grant "$PROJECT_MI" "AcrPull" "$ACR_ID"

echo "[+] Phase 2 — Runtime (per-agent identity)"
# Foundry User at BOTH account and project — required for hosted-agent runtime.
# The previous-version `Azure AI Developer` grant was removed: per the Microsoft
# Learn hosted-agent permissions reference it is "insufficient for Hosted agent
# scenarios" because it's scoped to Azure ML / Foundry hubs, not Foundry
# projects. Foundry User is the documented per-agent runtime role. (TD-30)
grant "$AGENT_PRINCIPAL" "$ROLE_FOUNDRY_USER"              "$ACCOUNT_ID"
grant "$AGENT_PRINCIPAL" "$ROLE_FOUNDRY_USER"              "$PROJECT_ID"
grant "$AGENT_PRINCIPAL" "Cognitive Services OpenAI User"  "$ACCOUNT_ID"
grant "$AGENT_PRINCIPAL" "Cognitive Services User"         "$ACCOUNT_ID"

echo
echo "[+] Done. Allow 5-15 min for propagation."
echo "    Phase 3 grants (Fabric / Content Safety / Cosmos) — run capability-specific scripts:"
echo "      foundry-guardrails/scripts/grant-cs-access.sh"
echo "      (Fabric: print-only today — see foundry-fabric/SKILL.md)"
