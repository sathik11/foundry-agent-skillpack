#!/usr/bin/env bash
# Discover both identities for a deployed Foundry hosted agent.
#
# Usage:
#   ./check-identities.sh <subscription_id> <rg> <foundry_account> <project> <agent_name>
set -euo pipefail

SUB="${1:?usage: $0 <sub> <rg> <account> <project> <agent_name>}"
RG="${2:?}"
ACCOUNT="${3:?}"
PROJECT="${4:?}"
AGENT="${5:?}"

echo "[+] Project MI..."
# api-version pinned to latest GA (2026-03-01) per Microsoft.CognitiveServices/accounts/projects.
# Bump when a newer GA ships and is verified in ARM (`az provider show -n Microsoft.CognitiveServices`).
PROJECT_MI=$(az rest --method get \
  --uri "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACCOUNT/projects/$PROJECT?api-version=2026-03-01" \
  --query identity.principalId -o tsv)

if [[ -z "$PROJECT_MI" || "$PROJECT_MI" == "null" ]]; then
  echo "[x] Project has no system-assigned MI. Enable it on the project resource." >&2
  exit 2
fi

echo "[+] Per-agent identity..."
AGENT_PRINCIPAL=$(azd ai agent show --name "$AGENT" --output json 2>/dev/null \
  | jq -r '.instance_identity.principal_id // empty')

if [[ -z "$AGENT_PRINCIPAL" ]]; then
  echo "[!] Per-agent identity not found. The agent may not have been deployed yet."
  echo "    Run: azd up"
fi

cat <<EOF
PROJECT_MI=$PROJECT_MI
AGENT_PRINCIPAL=$AGENT_PRINCIPAL
EOF
