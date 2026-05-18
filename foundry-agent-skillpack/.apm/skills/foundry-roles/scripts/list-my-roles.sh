#!/usr/bin/env bash
# Debug helper: dump every role the caller has across declared scopes.
#
# Usage:
#   ./list-my-roles.sh <scope1> [scope2 ...]
#
# Examples:
#   ./list-my-roles.sh /subscriptions/<sub>/resourceGroups/<rg>
#   ./list-my-roles.sh /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<acc>
#
# Useful before opening a new repo / before /prepare-deploy to know whether you'll
# need to emit any runbooks.
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <scope1> [scope2 ...]" >&2
  exit 64
fi

caller_oid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
caller_upn=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || echo "<unknown>")

if [[ -z "$caller_oid" ]]; then
  echo "[!] Not logged in. Run 'az login' first." >&2
  exit 2
fi

echo "[+] Signed in as: $caller_upn"
echo "    Object ID:   $caller_oid"
echo

for scope in "$@"; do
  echo "── Scope: $scope ──"
  az role assignment list \
    --assignee "$caller_oid" \
    --scope "$scope" \
    --include-inherited \
    --query "[].{role:roleDefinitionName, principalType:principalType, scope:scope}" \
    -o table 2>/dev/null \
    || echo "  (no Reader on scope, or no assignments)"
  echo
done
