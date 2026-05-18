#!/usr/bin/env bash
# Post-publish RBAC re-fan helper (TD-2). Thin wrapper that prepares the
# environment the /configure-rbac prompt expects when invoked with
# post_publish=true.
#
# This script does NOT itself execute role assignments — those go through the
# /configure-rbac prompt's Step 3 (Phase 3 capability-aware grants), which is
# the single source of truth for grant logic. This wrapper:
#
#   1. Verifies agent-status.json has a 'publish' block populated by
#      /publish-teams Step 4 (application_identity_principal_id present).
#   2. Verifies the application identity is resolvable in AAD.
#   3. Emits the exact /configure-rbac invocation line the caller should paste.
#   4. Optionally (with --run) execs the configure-rbac prompt via the local
#      prompt runner if one is wired in CI.
#
# Usage:
#   refan-rbac-post-publish.sh <agent_path> <agent_name> [--run]
#
# Read-only by default; --run requires the caller already has the rights
# /configure-rbac needs (User Access Administrator on the relevant scopes).

set -euo pipefail

AGENT_PATH="${1:?usage: refan-rbac-post-publish.sh <agent_path> <agent_name> [--run]}"
AGENT_NAME="${2:?usage: refan-rbac-post-publish.sh <agent_path> <agent_name> [--run]}"
RUN_MODE="${3:-}"

STATUS_FILE="$AGENT_PATH/agent-status.json"

if [[ ! -f "$STATUS_FILE" ]]; then
  echo "[x] $STATUS_FILE not found — run /publish-teams Step 4 first." >&2
  exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "[x] missing: jq" >&2; exit 3; }
command -v az >/dev/null 2>&1 || { echo "[x] missing: az" >&2; exit 3; }

APP_PRINCIPAL=$(jq -r '.publish.application_identity_principal_id // ""' "$STATUS_FILE")
BOT_APP_ID=$(jq -r '.publish.bot_app_id // ""' "$STATUS_FILE")
PUBLISHED_AT=$(jq -r '.publish.published_at // ""' "$STATUS_FILE")

if [[ -z "$APP_PRINCIPAL" || -z "$BOT_APP_ID" || -z "$PUBLISHED_AT" ]]; then
  echo "[x] publish block in $STATUS_FILE is incomplete." >&2
  echo "    application_identity_principal_id='$APP_PRINCIPAL'" >&2
  echo "    bot_app_id='$BOT_APP_ID'" >&2
  echo "    published_at='$PUBLISHED_AT'" >&2
  echo "    Re-run /publish-teams Step 4 to stamp them." >&2
  exit 4
fi

echo "[*] Resolving application identity in AAD…" >&2
SP_DISPLAY=$(az ad sp show --id "$APP_PRINCIPAL" --query displayName -o tsv 2>/dev/null || echo "")
if [[ -z "$SP_DISPLAY" ]]; then
  # Try by app id
  SP_DISPLAY=$(az ad sp show --id "$BOT_APP_ID" --query displayName -o tsv 2>/dev/null || echo "")
fi

cat <<EOF
APPLICATION_PRINCIPAL_ID=$APP_PRINCIPAL
BOT_APP_ID=$BOT_APP_ID
PUBLISHED_AT=$PUBLISHED_AT
APPLICATION_SP_DISPLAY_NAME=$SP_DISPLAY
EOF

{
  echo ""
  echo "─── RBAC re-fan plan ───"
  echo "  Pre-publish grants (under rbac.capability_grants) are PRESERVED for audit."
  echo "  New grants will be written under rbac.capability_grants_post_publish,"
  echo "  targeting application identity:"
  echo "    principal_id : $APP_PRINCIPAL"
  echo "    bot_app_id   : $BOT_APP_ID"
  [[ -n "$SP_DISPLAY" ]] && echo "    display_name : $SP_DISPLAY"
  echo ""
  echo "  Next step — paste this into your prompt runner:"
  echo ""
  echo "    /configure-rbac agent_path=$AGENT_PATH agent_name=$AGENT_NAME post_publish=true"
  echo ""
} >&2

if [[ "$RUN_MODE" == "--run" ]]; then
  echo "[!] --run flag set, but this wrapper does not execute /configure-rbac itself." >&2
  echo "    Paste the line above into your prompt runner (Copilot Chat, etc.)." >&2
  echo "    This boundary is deliberate: role assignments are mutating and should" >&2
  echo "    remain operator-visible." >&2
fi
