#!/usr/bin/env bash
# try-or-runbook.sh — Try an az command; on AuthorizationFailed, emit a runbook.
#
# This is the core primitive for operator_mode. Instead of preflight-checking
# whether the caller has a role and emitting a runbook if not, we just TRY the
# command. The API is the ultimate authority on permissions — our role heuristic
# can be wrong (inherited roles, PIM activations, custom roles, cross-tenant grants).
#
# Usage:
#   ./try-or-runbook.sh \
#     --role "Purview Information Protection Reader" \
#     --scope "/tenants/$TENANT_ID" \
#     --persona "Tenant Admin" \
#     --oid "$PRINCIPAL_ID" \
#     --why "Agent needs Purview classification access" \
#     --action "purview-dlp-grant" \
#     -- az rest --method POST --url "..." --body "..."
#
# When OPERATOR_MODE=false (env var), the command is NOT attempted:
#   - Emits the runbook immediately (old behavior).
#   - Exit 1 (blocked).
#
# Exit codes:
#   0 — command succeeded.
#   1 — authorization failed; runbook emitted.
#   2 — command failed for a non-auth reason; error printed.
set -euo pipefail

ROLE="" SCOPE="" PERSONA="Tenant Admin" OID="" WHY="" ACTION="grant"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)    ROLE="$2";    shift 2 ;;
    --scope)   SCOPE="$2";   shift 2 ;;
    --persona) PERSONA="$2"; shift 2 ;;
    --oid)     OID="$2";     shift 2 ;;
    --why)     WHY="$2";     shift 2 ;;
    --action)  ACTION="$2";  shift 2 ;;
    --)        shift; break ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

if [[ $# -eq 0 ]]; then
  echo "usage: $0 [--role R] [--scope S] [--persona P] [--oid O] [--why W] [--action A] -- <command...>" >&2
  exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- operator_mode=false: skip execution, emit runbook immediately ---
if [[ "${OPERATOR_MODE:-true}" == "false" ]]; then
  echo "[i] OPERATOR_MODE=false — skipping execution, emitting runbook." >&2
  if [[ -x "$SCRIPT_DIR/runbook-emit.sh" && -n "$ROLE" && -n "$SCOPE" ]]; then
    "$SCRIPT_DIR/runbook-emit.sh" \
      --action  "$ACTION" \
      --persona "$PERSONA" \
      --role    "$ROLE" \
      --scope   "$SCOPE" \
      --oid     "$OID" \
      --why     "$WHY"
  else
    echo "### Runbook: $ACTION" >&2
    echo "Role: $ROLE | Scope: $SCOPE | Principal: $OID" >&2
    echo "Command: $*" >&2
  fi
  exit 1
fi

# --- operator_mode=true (default): try the command ---
TMP_ERR=$(mktemp)
trap 'rm -f "$TMP_ERR"' EXIT

if "$@" 2>"$TMP_ERR"; then
  echo "[✓] $ACTION succeeded." >&2
  exit 0
fi

EXIT_CODE=$?

# Check if the failure is authorization-related
if grep -qiE '(AuthorizationFailed|Forbidden|403|InsufficientPrivileges|Authorization_RequestDenied|AccessDenied)' "$TMP_ERR" 2>/dev/null; then
  echo "[x] Authorization failed — emitting runbook for $PERSONA." >&2
  cat "$TMP_ERR" >&2
  echo >&2

  if [[ -x "$SCRIPT_DIR/runbook-emit.sh" && -n "$ROLE" && -n "$SCOPE" ]]; then
    "$SCRIPT_DIR/runbook-emit.sh" \
      --action  "$ACTION" \
      --persona "$PERSONA" \
      --role    "$ROLE" \
      --scope   "$SCOPE" \
      --oid     "$OID" \
      --why     "$WHY"
  else
    echo "### Runbook: $ACTION" >&2
    echo "Role: $ROLE | Scope: $SCOPE | Principal: $OID" >&2
    echo "Command: $*" >&2
  fi
  exit 1
fi

# Non-auth failure — print error and exit 2
echo "[x] Command failed (non-auth): exit $EXIT_CODE" >&2
cat "$TMP_ERR" >&2
exit 2
