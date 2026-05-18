#!/usr/bin/env bash
# Verify caller + per-agent SP RBAC against a single declared knowledge source.
#
# Usage:
#   ./verify-source-rbac.sh <kind> <resource_id> <caller_oid> <agent_principal_id>
#
# <kind> is one of:
#   foundry_iq | ai_search_direct | file_search_standard | blob_via_indexer | fabric_data_agent | fabric_direct_delta
#
# Required role on caller: Reader on the resource (to enumerate role assignments).
# When Reader is missing, prints a runbook via foundry-roles/runbook-emit.sh
# and exits 2 (degrade — caller decides whether to stop).
#
# Output: per-required-role verdict on stderr; structured PASS/FAIL on stdout.
#
# Exit codes:
#   0 — all required roles present
#   1 — at least one required role missing (specifics on stderr)
#   2 — couldn't determine (no Reader on scope, etc.)
set -euo pipefail

KIND="${1:?usage: $0 <kind> <resource_id> <caller_oid> <agent_principal_id>}"
RID="${2:?}"
CALLER_OID="${3:?}"
AGENT_OID="${4:?}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLES_DIR="$SCRIPT_DIR/../../foundry-roles/scripts"

# Per-kind required roles. Caller-side and agent-side.
case "$KIND" in
  foundry_iq)
    CALLER_ROLES=("Search Service Contributor" "Azure AI Project Manager")
    # Project MI — but verify-script uses agent_principal_id. Foundry IQ uses
    # Project MI for runtime, NOT the per-agent SP. Caller needs to verify the
    # Project MI separately via configure-rbac. Here we only verify caller.
    AGENT_ROLES=()
    AGENT_NOTE="Foundry IQ uses the Project MI (not the per-agent SP) for runtime KB calls."
    ;;
  ai_search_direct)
    CALLER_ROLES=("Search Service Contributor")
    AGENT_ROLES=("Search Index Data Reader")
    AGENT_NOTE="Per-agent SP needs read; add 'Search Index Data Contributor' if the agent writes."
    ;;
  file_search_standard)
    CALLER_ROLES=("Owner")  # broad — needed to grant the next two
    AGENT_ROLES=("Search Index Data Contributor" "Storage Blob Data Contributor")
    AGENT_NOTE="Project MI gets Search + Storage data-plane writes."
    ;;
  blob_via_indexer)
    CALLER_ROLES=("Search Service Contributor" "Owner")
    AGENT_ROLES=("Search Index Data Reader")
    AGENT_NOTE="Per-agent SP needs Search read; AI Search service MI separately needs Storage Blob Data Reader for ingestion."
    ;;
  fabric_data_agent|fabric_direct_delta)
    CALLER_ROLES=("Reader")
    AGENT_ROLES=()
    AGENT_NOTE="Fabric workspace role assignment for the per-agent SP is print-only (TD-1). See foundry-fabric/SKILL.md."
    ;;
  file_search_basic)
    CALLER_ROLES=("Azure AI User")
    AGENT_ROLES=()
    AGENT_NOTE="Microsoft-managed; no per-agent SP grants needed."
    ;;
  *)
    echo "[x] Unknown kind: $KIND" >&2
    echo "    Supported: foundry_iq | ai_search_direct | file_search_basic | file_search_standard | blob_via_indexer | fabric_data_agent | fabric_direct_delta" >&2
    exit 64
    ;;
esac

# Enumerate the caller's roles on the resource.
caller_roles_actual=()
agent_roles_actual=()
auth_failed=0

if list_caller=$(az role assignment list --assignee "$CALLER_OID" --scope "$RID" --include-inherited \
                  --query "[].roleDefinitionName" -o tsv 2>/tmp/vsr.err); then
  while IFS= read -r r; do [[ -n "$r" ]] && caller_roles_actual+=("$r"); done <<< "$list_caller"
else
  if grep -q AuthorizationFailed /tmp/vsr.err; then auth_failed=1; fi
fi

if [[ $auth_failed -eq 1 ]]; then
  echo "[!] No Reader on $RID — cannot enumerate role assignments." >&2
  if [[ -x "$ROLES_DIR/runbook-emit.sh" ]]; then
    "$ROLES_DIR/runbook-emit.sh" \
      --action "verify-source-rbac" --persona "DevOps" \
      --role "Reader" --scope "$RID" --oid "$CALLER_OID" \
      --why "Knowledge-source RBAC preflight needs Reader to enumerate roles"
  fi
  exit 2
fi

# Enumerate the per-agent SP's roles on the resource (only if we expect any).
if (( ${#AGENT_ROLES[@]} > 0 )); then
  if list_agent=$(az role assignment list --assignee "$AGENT_OID" --scope "$RID" --include-inherited \
                   --query "[].roleDefinitionName" -o tsv 2>/dev/null); then
    while IFS= read -r r; do [[ -n "$r" ]] && agent_roles_actual+=("$r"); done <<< "$list_agent"
  fi
fi

# Compare.
fail=0
for required in "${CALLER_ROLES[@]}"; do
  matched=0
  for actual in "${caller_roles_actual[@]}"; do
    if [[ "$actual" == "$required" || "$actual" == "Owner" ]]; then matched=1; break; fi
  done
  if (( matched )); then
    echo "[+] Caller has '$required' on $(basename "$RID")"
    echo "PASS caller $required"
  else
    echo "[x] Caller LACKS '$required' on $(basename "$RID")" >&2
    echo "FAIL caller $required"
    fail=1
  fi
done

for required in "${AGENT_ROLES[@]}"; do
  matched=0
  for actual in "${agent_roles_actual[@]}"; do
    if [[ "$actual" == "$required" || "$actual" == "Owner" ]]; then matched=1; break; fi
  done
  if (( matched )); then
    echo "[+] Per-agent SP has '$required' on $(basename "$RID")"
    echo "PASS agent $required"
  else
    echo "[x] Per-agent SP LACKS '$required' on $(basename "$RID") — apply via /configure-rbac" >&2
    echo "FAIL agent $required"
    fail=1
  fi
done

if [[ -n "$AGENT_NOTE" ]]; then
  echo "    NOTE: $AGENT_NOTE" >&2
fi

exit $fail
