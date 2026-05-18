#!/usr/bin/env bash
# Grant per-agent identity Cognitive Services User on a Content Safety resource.
# Phase B — runs ONLY after `azd up` has created the per-agent identity.
#
# Usage:
#   ./grant-cs-access.sh <agent_name> <cs_resource_id>
set -euo pipefail

AGENT_NAME="${1:?usage: $0 <agent_name> <cs_resource_id>}"
CS_ID="${2:?usage: $0 <agent_name> <cs_resource_id>}"

echo "[+] Resolving per-agent identity for ${AGENT_NAME}..."
PRINCIPAL_ID=$(azd ai agent show --name "$AGENT_NAME" --output json \
  | jq -r '.instance_identity.principal_id')

if [[ -z "$PRINCIPAL_ID" || "$PRINCIPAL_ID" == "null" ]]; then
  echo "[x] No instance_identity yet. Run 'azd up' first." >&2
  exit 1
fi

echo "[+] Granting Cognitive Services User on $CS_ID to $PRINCIPAL_ID..."
az role assignment create \
  --assignee-object-id "$PRINCIPAL_ID" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope "$CS_ID"

echo "[+] Granted. Allow 5-15 min for propagation, then env-var-only redeploy with AZURE_CONTENT_SAFETY_ENDPOINT."
