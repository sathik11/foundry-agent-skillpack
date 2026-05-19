#!/usr/bin/env bash
# Ensure a resource provider is registered in the subscription.
# Operator-mode aware: tries az provider register; runbook on 403.
#
# Usage:
#   ./ensure-provider-registration.sh <provider_namespace> [<subscription_id>]
#
# Examples:
#   ./ensure-provider-registration.sh Microsoft.BotService
#   ./ensure-provider-registration.sh Microsoft.CognitiveServices <sub-id>
#
# Environment:
#   OPERATOR_MODE  — "true" (default): attempt registration. "false": check + runbook.
#
# Exit codes:
#   0 — provider already registered or registration succeeded.
#   1 — registration needed but caller lacks rights; runbook emitted.
#   2 — unexpected error.
set -euo pipefail

PROVIDER="${1:?usage: $0 <provider_namespace> [<subscription_id>]}"
SUB="${2:-$(az account show --query id -o tsv)}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$SCRIPT_DIR"

# Check current state
STATE=$(az provider show --namespace "$PROVIDER" --subscription "$SUB" --query registrationState -o tsv 2>/dev/null || echo "Unknown")

if [[ "$STATE" == "Registered" ]]; then
  echo "PROVIDER_STATE=Registered"
  echo "PROVIDER_NAME=$PROVIDER"
  echo "[✓] $PROVIDER already registered in subscription $SUB." >&2
  exit 0
fi

echo "[i] $PROVIDER is '$STATE' in subscription $SUB. Attempting registration..." >&2

"$ROLES_DIR/try-or-runbook.sh" \
  --role "Contributor" \
  --scope "/subscriptions/$SUB" \
  --persona "Subscription Contributor" \
  --oid "$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo unknown)" \
  --why "Resource provider $PROVIDER must be registered for the agent to use this service." \
  --action "provider-register" \
  -- az provider register --namespace "$PROVIDER" --subscription "$SUB" --wait

RC=$?
if [[ $RC -eq 0 ]]; then
  echo "PROVIDER_STATE=Registered"
  echo "PROVIDER_NAME=$PROVIDER"
else
  echo "PROVIDER_STATE=$STATE"
  echo "PROVIDER_NAME=$PROVIDER"
fi
exit $RC
