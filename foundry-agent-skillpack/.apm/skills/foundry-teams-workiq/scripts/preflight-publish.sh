#!/usr/bin/env bash
# Preflight checks for /publish-teams (TD-2). Emits KEY=VALUE on stdout, human verdict on stderr.
# Exits non-zero on any hard-gate failure.
#
# Usage:
#   preflight-publish.sh <agent_path> <agent_name> [<bot_app_id>]
#
# Emitted keys (see foundry-deploy/agent-status-schema.md § publish):
#   AGENT_IDENTITY_MODEL             new|legacy
#   BOT_SERVICE_RP_REGISTERED        true|false           [HARD GATE]
#   BYO_VNET_PUBLIC_BOT_MISMATCH     true|false           [HARD GATE if true]
#   EVALS_CONTINUOUS_RULE_ID         <rule-id>|<empty>    [HARD GATE if empty]
#   PURVIEW_ENABLED                  true|false           [HARD GATE if false]
#   PUBLISH_METADATA_SECRET_SCAN     clean|findings       [HARD GATE if findings]
#   PUBLISH_METADATA_SECRET_FINDINGS <csv of field names where findings hit>
#
# Read-only: makes no Azure mutations. Reader on the agent project + subscription is sufficient.

set -euo pipefail

AGENT_PATH="${1:?usage: preflight-publish.sh <agent_path> <agent_name> [<bot_app_id>]}"
AGENT_NAME="${2:?usage: preflight-publish.sh <agent_path> <agent_name> [<bot_app_id>]}"
BOT_APP_ID="${3:-}"

CAPS_FILE="$AGENT_PATH/agent-capabilities.yaml"
STATUS_FILE="$AGENT_PATH/agent-status.json"

if [[ ! -f "$CAPS_FILE" ]]; then
  echo "[x] $CAPS_FILE not found — run /prepare-deploy first." >&2
  exit 2
fi
if [[ ! -f "$STATUS_FILE" ]]; then
  echo "[x] $STATUS_FILE not found — run /prepare-deploy then /configure-rbac first." >&2
  exit 2
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "[x] missing: $1" >&2; exit 3; }; }
need jq
need az

# ─── Gate 1: Microsoft.BotService RP registration ──────────────────────────────
echo "[*] Checking Microsoft.BotService RP registration…" >&2
RP_STATE=$(az provider show -n Microsoft.BotService --query registrationState -o tsv 2>/dev/null || echo "Unknown")
if [[ "$RP_STATE" == "Registered" ]]; then
  BOT_SERVICE_RP_REGISTERED=true
else
  BOT_SERVICE_RP_REGISTERED=false
fi

# ─── Identity model detection ─────────────────────────────────────────────────
# We look at the deployed agent (if it has been deployed). If agent.identity is
# present in the local agent.yaml, we infer 'new'; otherwise 'legacy'. This is a
# best-effort hint — the canonical answer is `mcp_foundry_mcp_agent_get`, but
# this script must work without an MCP roundtrip.
AGENT_YAML="$AGENT_PATH/agent.yaml"
if [[ -f "$AGENT_YAML" ]] && grep -qE '^[[:space:]]*identity:[[:space:]]*$|^[[:space:]]*identity:[[:space:]]*\{' "$AGENT_YAML"; then
  AGENT_IDENTITY_MODEL=new
else
  AGENT_IDENTITY_MODEL=legacy
fi

# ─── Gate 2: BYO-VNet ↔ public Bot Service mismatch ──────────────────────────
NETWORK_CLASS=$(jq -r '.network.class // empty' "$CAPS_FILE" 2>/dev/null || true)
if [[ -z "$NETWORK_CLASS" ]]; then
  # YAML, not JSON — fall back to grep
  NETWORK_CLASS=$(awk '/^[[:space:]]*network:/,/^[^[:space:]]/' "$CAPS_FILE" \
    | awk -F':' '/^[[:space:]]+class:/ {gsub(/[[:space:]"]/,"",$2); print $2; exit}')
fi
if [[ "$NETWORK_CLASS" == "byo_vnet" ]]; then
  BYO_VNET_PUBLIC_BOT_MISMATCH=true
else
  BYO_VNET_PUBLIC_BOT_MISMATCH=false
fi

# ─── Gate 3: continuous eval rule present ────────────────────────────────────
EVALS_CONTINUOUS_RULE_ID=$(jq -r '.evals.continuous_rule_id // ""' "$STATUS_FILE" 2>/dev/null || echo "")

# ─── Gate 4: Purview middleware enabled ──────────────────────────────────────
PURVIEW_ENABLED=$(jq -r '.rbac.capability_grants.purview.toggle_enabled // false' "$STATUS_FILE" 2>/dev/null || echo "false")
if [[ "$PURVIEW_ENABLED" != "true" ]]; then
  # Fall back to capabilities manifest declared intent
  PURVIEW_ENABLED=$(awk '/^[[:space:]]*purview:/,/^[^[:space:]]/' "$CAPS_FILE" \
    | awk -F':' '/^[[:space:]]+enabled:/ {gsub(/[[:space:]"]/,"",$2); print $2; exit}')
  [[ -z "$PURVIEW_ENABLED" ]] && PURVIEW_ENABLED=false
fi

# ─── Gate 5: publish-metadata secret scan ────────────────────────────────────
# Scan the fields a publish event would surface to external consumers.
# Regex set documented in publish-flow.md § Step 5.
PUBLISH_METADATA_SECRET_FINDINGS=""

scan_field() {
  local field="$1" value="$2"
  [[ -z "$value" ]] && return
  # AAD secret (tilde-separated, 34+ chars before ~)
  if echo "$value" | grep -qE '[A-Za-z0-9~._\-]{34,}~[A-Za-z0-9~._\-]{3,}'; then
    PUBLISH_METADATA_SECRET_FINDINGS+="${field}:aad_secret,"
  fi
  # JWT
  if echo "$value" | grep -qE 'eyJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}'; then
    PUBLISH_METADATA_SECRET_FINDINGS+="${field}:jwt,"
  fi
  # Connection-string fragments
  if echo "$value" | grep -qE '(AccountKey|SharedAccessKey|InstrumentationKey)='; then
    PUBLISH_METADATA_SECRET_FINDINGS+="${field}:conn_string,"
  fi
}

DISPLAY_NAME=$(awk -F':' '/^[[:space:]]*display_name:/ {sub(/^[[:space:]]*display_name:[[:space:]]*/,""); print; exit}' "$CAPS_FILE" | tr -d '"')
DESCRIPTION=$(awk -F':' '/^[[:space:]]*description:/ {sub(/^[[:space:]]*description:[[:space:]]*/,""); print; exit}' "$CAPS_FILE" | tr -d '"')

scan_field "display_name" "$DISPLAY_NAME"
scan_field "description"  "$DESCRIPTION"

if [[ -n "$PUBLISH_METADATA_SECRET_FINDINGS" ]]; then
  PUBLISH_METADATA_SECRET_SCAN=findings
  # Strip trailing comma
  PUBLISH_METADATA_SECRET_FINDINGS="${PUBLISH_METADATA_SECRET_FINDINGS%,}"
else
  PUBLISH_METADATA_SECRET_SCAN=clean
fi

# ─── Emit ─────────────────────────────────────────────────────────────────────
cat <<EOF
AGENT_IDENTITY_MODEL=$AGENT_IDENTITY_MODEL
BOT_SERVICE_RP_REGISTERED=$BOT_SERVICE_RP_REGISTERED
BYO_VNET_PUBLIC_BOT_MISMATCH=$BYO_VNET_PUBLIC_BOT_MISMATCH
EVALS_CONTINUOUS_RULE_ID=$EVALS_CONTINUOUS_RULE_ID
PURVIEW_ENABLED=$PURVIEW_ENABLED
PUBLISH_METADATA_SECRET_SCAN=$PUBLISH_METADATA_SECRET_SCAN
PUBLISH_METADATA_SECRET_FINDINGS=$PUBLISH_METADATA_SECRET_FINDINGS
EOF

# ─── Human verdict (stderr) + exit code ──────────────────────────────────────
fail=0
{
  echo ""
  echo "─── Preflight verdict for publish ───"
  [[ "$BOT_SERVICE_RP_REGISTERED" == "true" ]] \
    && echo "  [ok] Microsoft.BotService RP registered" \
    || { echo "  [x]  Microsoft.BotService RP NOT registered — run: az provider register -n Microsoft.BotService"; fail=1; }
  [[ "$BYO_VNET_PUBLIC_BOT_MISMATCH" == "false" ]] \
    && echo "  [ok] No BYO-VNet ↔ public Bot Service mismatch" \
    || { echo "  [!]  BYO-VNet detected; Bot Service is public-egress today. Document the exception or route via PE."; fail=1; }
  [[ -n "$EVALS_CONTINUOUS_RULE_ID" ]] \
    && echo "  [ok] Continuous eval rule present: $EVALS_CONTINUOUS_RULE_ID" \
    || { echo "  [x]  Continuous eval rule NOT configured — run: /setup-evals continuous"; fail=1; }
  [[ "$PURVIEW_ENABLED" == "true" ]] \
    && echo "  [ok] Purview middleware enabled" \
    || { echo "  [x]  Purview middleware NOT enabled — run: /setup-purview"; fail=1; }
  [[ "$PUBLISH_METADATA_SECRET_SCAN" == "clean" ]] \
    && echo "  [ok] Publish-metadata secret scan: clean" \
    || { echo "  [x]  Publish-metadata secret scan FOUND matches in: $PUBLISH_METADATA_SECRET_FINDINGS"; fail=1; }
  echo "  [i]  Agent identity model: $AGENT_IDENTITY_MODEL"
  echo ""
  [[ $fail -eq 0 ]] \
    && echo "  Result: READY TO PUBLISH" \
    || echo "  Result: BLOCKED — resolve hard gates above, then re-run preflight-publish.sh"
} >&2

exit $fail
