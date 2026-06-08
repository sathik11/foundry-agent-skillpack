#!/usr/bin/env bash
# Preflight: does the caller have <role> at <scope>?
#
# Usage:
#   ./preflight-role.sh <role_name_or_id> <scope> [--persona <hint>] [--why <one-liner>] [--action <keyword>]
#
# Exit codes:
#   0 — caller has the role (or a higher one that contains it). Proceed.
#   1 — caller lacks the role. Runbook is emitted to stdout. Caller (the calling
#       script) decides whether to stop or degrade.
#   2 — couldn't determine (no Reader on scope, az not logged in, etc.).
#       Runbook is emitted as informational.
#
# Containment rule: Owner / Contributor / User Access Administrator are treated as
# satisfying any role at the same-or-narrower scope ONLY when the wanted role is
# in a known equivalence list — we don't pretend Contributor grants RBAC writes.
set -euo pipefail

ROLE="${1:?usage: $0 <role> <scope> [--persona X] [--why X] [--action X]}"
SCOPE="${2:?usage: $0 <role> <scope> [--persona X] [--why X] [--action X]}"
shift 2

PERSONA="DevOps"
WHY="skillpack step"
ACTION="grant"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --persona) PERSONA="$2"; shift 2 ;;
    --why)     WHY="$2";     shift 2 ;;
    --action)  ACTION="$2";  shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

caller_oid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "$caller_oid" ]]; then
  echo "[!] Not logged in to az. Run 'az login' first." >&2
  exit 2
fi

# az role assignment list against the scope. Requires Reader on the scope.
# We capture stderr to detect AuthorizationFailed.
# We pull roleDefinitionId too so we can match by GUID — necessary because
# during the Foundry RBAC rename rollout (TD-30), `az` may return either the
# old or new name depending on backend caching, but the role definition GUID
# is stable.
mapfile -t roles < <(
  az role assignment list \
    --assignee "$caller_oid" \
    --scope "$SCOPE" \
    --include-inherited \
    --query "[].roleDefinitionName" -o tsv 2>/tmp/preflight-role.err || true
)
mapfile -t role_ids < <(
  az role assignment list \
    --assignee "$caller_oid" \
    --scope "$SCOPE" \
    --include-inherited \
    --query "[].roleDefinitionId" -o tsv 2>/dev/null || true
)

if grep -q AuthorizationFailed /tmp/preflight-role.err 2>/dev/null; then
  echo "[!] No Reader on scope $SCOPE — cannot enumerate role assignments." >&2
  "$SCRIPT_DIR/runbook-emit.sh" \
    --action "$ACTION" \
    --persona "$PERSONA" \
    --role   "Reader" \
    --scope  "$SCOPE" \
    --oid    "$caller_oid" \
    --why    "Preflight needs Reader to enumerate roles on this scope. Without it, downstream steps may silently 403."
  exit 2
fi

# Equivalence: Owner / User Access Administrator subsume RBAC-write roles.
# Owner / Contributor subsume any data-plane action that doesn't require RBAC writes.
#
# Rename aliases (TD-30): Microsoft renamed four Foundry data-plane roles. During
# the rollout, the caller may pass the new name while Azure returns the old name
# (or vice versa). Treat each pair as equivalent. Role IDs are stable so a GUID
# match below is the future-proof path.
declare -A RENAME_ALIASES=(
  ["Foundry User"]="Azure AI User"
  ["Azure AI User"]="Foundry User"
  ["Foundry Owner"]="Azure AI Owner"
  ["Azure AI Owner"]="Foundry Owner"
  ["Foundry Account Owner"]="Azure AI Account Owner"
  ["Azure AI Account Owner"]="Foundry Account Owner"
  ["Foundry Project Manager"]="Azure AI Project Manager"
  ["Azure AI Project Manager"]="Foundry Project Manager"
)
declare -A ROLE_GUIDS=(
  ["Foundry User"]="53ca6127-db72-4b80-b1b0-d745d6d5456d"
  ["Azure AI User"]="53ca6127-db72-4b80-b1b0-d745d6d5456d"
  ["Foundry Owner"]="c883944f-8b7b-4483-af10-35834be79c4a"
  ["Azure AI Owner"]="c883944f-8b7b-4483-af10-35834be79c4a"
  ["Foundry Account Owner"]="e47c6f54-e4a2-4754-9501-8e0985b135e1"
  ["Azure AI Account Owner"]="e47c6f54-e4a2-4754-9501-8e0985b135e1"
  ["Foundry Project Manager"]="eadc314b-1a2d-4efa-be10-5d325db5065e"
  ["Azure AI Project Manager"]="eadc314b-1a2d-4efa-be10-5d325db5065e"
)
WANT_ALIAS="${RENAME_ALIASES[$ROLE]:-}"
WANT_GUID="${ROLE_GUIDS[$ROLE]:-}"
# If caller passed a bare GUID, match it directly too.
if [[ "$ROLE" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
  WANT_GUID="$ROLE"
fi

have_role=0
for r in "${roles[@]}"; do
  if [[ "$r" == "$ROLE" || "$r" == "Owner" || ( -n "$WANT_ALIAS" && "$r" == "$WANT_ALIAS" ) ]]; then
    have_role=1; break
  fi
  # Treat User Access Administrator as a superset only for grant-y roles.
  case "$ROLE" in
    "User Access Administrator"|"Owner")
      [[ "$r" == "User Access Administrator" ]] && { have_role=1; break; } ;;
  esac
done

# GUID-based fallback match (rolling-rename-proof per TD-30).
if (( ! have_role )) && [[ -n "$WANT_GUID" ]]; then
  for rid in "${role_ids[@]}"; do
    if [[ "$rid" == *"/$WANT_GUID" ]]; then
      have_role=1; break
    fi
  done
fi

if (( have_role )); then
  echo "[+] Caller has '$ROLE' (or equivalent) at $SCOPE."
  exit 0
fi

echo "[x] Caller lacks '$ROLE' at $SCOPE. Emitting runbook…" >&2
"$SCRIPT_DIR/runbook-emit.sh" \
  --action  "$ACTION" \
  --persona "$PERSONA" \
  --role    "$ROLE" \
  --scope   "$SCOPE" \
  --oid     "$caller_oid" \
  --why     "$WHY"
exit 1
