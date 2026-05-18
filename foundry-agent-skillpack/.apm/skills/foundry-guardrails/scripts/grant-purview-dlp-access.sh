#!/usr/bin/env bash
# Grant per-agent identity the Purview roles needed by purview_dlp_middleware.py.
# Phase B — runs ONLY after `azd up` has created the per-agent identity.
#
# These roles are TENANT-scoped. The caller almost always lacks the rights to
# grant them (typically Privileged Role Administrator + Purview Admin). When
# that's the case, the script emits a runbook block via foundry-roles for the
# tenant admin to action.
#
# Usage:
#   ./grant-purview-dlp-access.sh <agent_name>
#
# Required role on caller:
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

# Roles needed — Entra-side. Names can vary by tenant; use the canonical IDs.
# Purview Information Protection Reader role assignment lives in Microsoft Graph;
# we delegate to a runbook because grants here often require Privileged Role Admin.
TENANT_ID=$(az account show --query tenantId -o tsv)

echo
echo "[+] Two grants are required for the per-agent SP ($PRINCIPAL_ID):"
echo "    1. Purview Information Protection Reader (or custom equivalent)"
echo "    2. AIP Service Reader"
echo
echo "[i] Both are TENANT-scoped. Most callers lack the rights to apply these."
echo "    Emitting runbook for the tenant administrator to action."
echo

# Use the runbook emitter for both grants — paste-ready into ServiceNow/Slack.
if [[ -x "$ROLES_DIR/runbook-emit.sh" ]]; then
  "$ROLES_DIR/runbook-emit.sh" \
    --action "purview-dlp-grant" \
    --persona "Tenant Admin" \
    --role   "Purview Information Protection Reader" \
    --scope  "/tenants/$TENANT_ID" \
    --oid    "$PRINCIPAL_ID" \
    --why    "Foundry hosted agent '${AGENT_NAME}' needs to call the Purview classification API for runtime DLP enforcement. See foundry-guardrails/purview-dlp.md."

  "$ROLES_DIR/runbook-emit.sh" \
    --action "purview-dlp-grant" \
    --persona "Tenant Admin" \
    --role   "AIP Service Reader" \
    --scope  "/tenants/$TENANT_ID" \
    --oid    "$PRINCIPAL_ID" \
    --why    "Foundry hosted agent '${AGENT_NAME}' needs to resolve sensitivity labels for runtime DLP enforcement. See foundry-guardrails/purview-dlp.md."
else
  cat <<EOF

### 🔐 Action required: purview-dlp-grant (Tenant Admin)

Two role grants needed for principal $PRINCIPAL_ID in tenant $TENANT_ID:
  1. Purview Information Protection Reader
  2. AIP Service Reader

Apply via Purview portal → Roles & scopes → Role groups; OR via Graph PowerShell.

Why: agent '${AGENT_NAME}' needs runtime DLP classification.
See foundry-guardrails/purview-dlp.md § 'Required RBAC' for context.

EOF
fi

echo "[+] Done emitting runbooks. Notify tenant admin; allow up to 60 min for"
echo "    Purview-side propagation, then run /verify-agent to confirm DLP spans."
