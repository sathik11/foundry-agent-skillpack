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
mapfile -t roles < <(
  az role assignment list \
    --assignee "$caller_oid" \
    --scope "$SCOPE" \
    --include-inherited \
    --query "[].roleDefinitionName" -o tsv 2>/tmp/preflight-role.err || true
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
have_role=0
for r in "${roles[@]}"; do
  if [[ "$r" == "$ROLE" || "$r" == "Owner" ]]; then
    have_role=1; break
  fi
  # Treat User Access Administrator as a superset only for grant-y roles.
  case "$ROLE" in
    "User Access Administrator"|"Owner")
      [[ "$r" == "User Access Administrator" ]] && { have_role=1; break; } ;;
  esac
done

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
