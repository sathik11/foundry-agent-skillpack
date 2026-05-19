#!/usr/bin/env bash
# Grant a per-agent identity a role on a Fabric workspace via the Fabric REST API.
# Operator-mode aware: tries Fabric REST; runbook on 401/403.
#
# This partially addresses TD-1 (Fabric workspace role assignment is print-only).
# The Fabric REST API requires a Fabric-audience token, not the standard Azure
# Management token from `az`. This script acquires a Fabric-aud token via
# `az account get-access-token --resource https://api.fabric.microsoft.com` —
# which works when the caller is a Fabric Admin or workspace Admin already logged
# in with the right audience.
#
# Usage:
#   ./grant-fabric-workspace-role.sh <workspace_id> <principal_id> <role>
#
# Args:
#   workspace_id  — Fabric workspace GUID
#   principal_id  — Object ID of the per-agent service principal
#   role          — One of: Admin, Member, Contributor, Viewer
#
# Environment:
#   OPERATOR_MODE  — "true" (default): attempt Fabric REST. "false": print-only.
#
# Exit codes:
#   0 — role assignment succeeded or already existed.
#   1 — authorization failed; runbook emitted.
#   2 — unexpected error (wrong workspace ID, network issue, etc.).
set -euo pipefail

WORKSPACE_ID="${1:?usage: $0 <workspace_id> <principal_id> <role>}"
PRINCIPAL_ID="${2:?usage: $0 <workspace_id> <principal_id> <role>}"
ROLE="${3:?usage: $0 <workspace_id> <principal_id> <role>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/../../foundry-roles/scripts"

# Validate role
case "$ROLE" in
  Admin|Member|Contributor|Viewer) ;;
  *) echo "[x] Invalid role '$ROLE'. Must be: Admin, Member, Contributor, Viewer." >&2; exit 64 ;;
esac

# Attempt to get a Fabric-audience token
echo "[i] Acquiring Fabric-audience token..." >&2
FABRIC_TOKEN=$(az account get-access-token \
  --resource "https://api.fabric.microsoft.com" \
  --query accessToken -o tsv 2>/dev/null || true)

if [[ -z "$FABRIC_TOKEN" ]]; then
  echo "[x] Could not acquire Fabric-audience token." >&2
  echo "    Run: az login --scope https://api.fabric.microsoft.com/.default" >&2
  echo >&2
  echo "### Runbook: fabric-workspace-role-grant (Fabric Admin)" >&2
  echo >&2
  echo "1. Navigate to Fabric portal → Workspaces → select workspace $WORKSPACE_ID" >&2
  echo "2. Manage access → Add → paste principal $PRINCIPAL_ID → select role '$ROLE' → Add" >&2
  echo >&2
  echo "OR via REST (after az login --scope https://api.fabric.microsoft.com/.default):" >&2
  echo '```' >&2
  echo "az rest --method POST \\" >&2
  echo "  --url \"https://api.fabric.microsoft.com/v1/workspaces/$WORKSPACE_ID/roleAssignments\" \\" >&2
  echo "  --headers \"Content-Type=application/json\" \\" >&2
  echo "  --body '{\"principal\":{\"id\":\"$PRINCIPAL_ID\",\"type\":\"ServicePrincipal\"},\"role\":\"$ROLE\"}'" >&2
  echo '```' >&2
  exit 1
fi

# Try the REST call via try-or-runbook
BODY="{\"principal\":{\"id\":\"$PRINCIPAL_ID\",\"type\":\"ServicePrincipal\"},\"role\":\"$ROLE\"}"

"$ROLES_DIR/try-or-runbook.sh" \
  --role "Fabric Workspace Admin" \
  --scope "workspace/$WORKSPACE_ID" \
  --persona "Fabric Admin" \
  --oid "$PRINCIPAL_ID" \
  --why "Per-agent identity needs '$ROLE' on the Fabric workspace to access lakehouse / warehouse / semantic model data." \
  --action "fabric-workspace-role-grant" \
  -- az rest --method POST \
    --url "https://api.fabric.microsoft.com/v1/workspaces/$WORKSPACE_ID/roleAssignments" \
    --headers "Content-Type=application/json" "Authorization=Bearer $FABRIC_TOKEN" \
    --body "$BODY"

RC=$?
if [[ $RC -eq 0 ]]; then
  echo "FABRIC_WORKSPACE_ROLE=granted"
  echo "FABRIC_WORKSPACE_ID=$WORKSPACE_ID"
  echo "FABRIC_PRINCIPAL_ID=$PRINCIPAL_ID"
  echo "FABRIC_ROLE=$ROLE"
fi
exit $RC
