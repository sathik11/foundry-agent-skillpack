#!/usr/bin/env bash
# Grant per-agent identity the Purview roles needed by purview_dlp_middleware.py.
# Phase B — runs ONLY after `azd up` has created the per-agent identity.
#
# Operator-mode aware (v0.21.0):
#   OPERATOR_MODE=true  (default) → try the grant via Graph REST; runbook on 403.
#   OPERATOR_MODE=false            → emit runbook immediately (v0.20 behavior).
#
# These roles are TENANT-scoped. The caller may or may not have the rights to
# grant them. Instead of assuming they can't, we try first (when operator_mode
# is true) and fall back to a runbook if the API returns 403.
#
# Usage:
#   ./grant-purview-dlp-access.sh <agent_name>
#
# Required role on caller (if attempting grant):
#   - Privileged Role Administrator (Entra) to grant Entra app role assignments
#   - OR Purview Compliance Administrator (Purview tenant role)
set -euo pipefail

AGENT_NAME="${1:?usage: $0 <agent_name>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/../../foundry-roles/scripts"

echo "[+] Resolving per-agent identity for ${AGENT_NAME}..."
PRINCIPAL_ID=$(azd ai agent show --name "$AGENT_NAME" --output json \
  | jq -r '.instance_identity.principal_id // empty')

if [[ -z "$PRINCIPAL_ID" ]]; then
  echo "[x] No instance_identity yet. Run 'azd up' first." >&2
  exit 1
fi

CALLER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "$CALLER_OID" ]]; then
  echo "[!] Not logged in to az. Run 'az login' first." >&2
  exit 1
fi

TENANT_ID=$(az account show --query tenantId -o tsv)

echo
echo "[+] Two grants are required for the per-agent SP ($PRINCIPAL_ID):"
echo "    1. Purview Information Protection Reader (or custom equivalent)"
echo "    2. AIP Service Reader"
echo

# Resolve the SP app ID for Graph call
SP_APP_ID=$(az ad sp show --id "$PRINCIPAL_ID" --query appId -o tsv 2>/dev/null || true)

GRANT_COUNT=0

# --- Grant 1: Purview Information Protection Reader ---
echo "[+] Grant 1: Purview Information Protection Reader..." >&2
"$ROLES_DIR/try-or-runbook.sh" \
  --role "Purview Information Protection Reader" \
  --scope "/tenants/$TENANT_ID" \
  --persona "Tenant Admin" \
  --oid "$PRINCIPAL_ID" \
  --why "Foundry hosted agent '${AGENT_NAME}' needs to call the Purview classification API for runtime DLP enforcement. See foundry-guardrails/purview-dlp.md." \
  --action "purview-dlp-grant" \
  -- az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PRINCIPAL_ID/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$PRINCIPAL_ID\",\"resourceId\":\"$PRINCIPAL_ID\",\"appRoleId\":\"00000000-0000-0000-0000-000000000000\"}" \
  && GRANT_COUNT=$((GRANT_COUNT + 1)) || true

# --- Grant 2: AIP Service Reader ---
echo "[+] Grant 2: AIP Service Reader..." >&2
"$ROLES_DIR/try-or-runbook.sh" \
  --role "AIP Service Reader" \
  --scope "/tenants/$TENANT_ID" \
  --persona "Tenant Admin" \
  --oid "$PRINCIPAL_ID" \
  --why "Foundry hosted agent '${AGENT_NAME}' needs to resolve sensitivity labels for runtime DLP enforcement. See foundry-guardrails/purview-dlp.md." \
  --action "purview-dlp-grant" \
  -- az rest --method POST \
    --url "https://graph.microsoft.com/v1.0/servicePrincipals/$PRINCIPAL_ID/appRoleAssignments" \
    --headers "Content-Type=application/json" \
    --body "{\"principalId\":\"$PRINCIPAL_ID\",\"resourceId\":\"$PRINCIPAL_ID\",\"appRoleId\":\"00000000-0000-0000-0000-000000000001\"}" \
  && GRANT_COUNT=$((GRANT_COUNT + 1)) || true

echo
if [[ $GRANT_COUNT -eq 2 ]]; then
  echo "[✓] Both Purview DLP grants applied. Allow up to 60 min for"
  echo "    Purview-side propagation, then run /verify-agent to confirm DLP spans."
else
  echo "[!] $((2 - GRANT_COUNT)) grant(s) emitted as runbook(s). Have the tenant admin"
  echo "    action them, then re-run /verify-agent to confirm DLP spans."
fi
