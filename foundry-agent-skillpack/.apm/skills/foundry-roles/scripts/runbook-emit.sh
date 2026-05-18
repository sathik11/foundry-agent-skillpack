#!/usr/bin/env bash
# Emit a paste-ready runbook block for a role grant the caller cannot self-service.
#
# Usage:
#   ./runbook-emit.sh \
#     --action <keyword> --persona <DevOps|Tenant Admin|...> \
#     --role <role_name> --scope <full_scope> --oid <object_id_to_grant_to> \
#     --why <one-liner>
#
# Output: markdown block on stdout (paste into ServiceNow / Slack / Jira).
set -euo pipefail

ACTION=""
PERSONA="DevOps"
ROLE=""
SCOPE=""
OID=""
WHY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)  ACTION="$2";  shift 2 ;;
    --persona) PERSONA="$2"; shift 2 ;;
    --role)    ROLE="$2";    shift 2 ;;
    --scope)   SCOPE="$2";   shift 2 ;;
    --oid)     OID="$2";     shift 2 ;;
    --why)     WHY="$2";     shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 64 ;;
  esac
done

: "${ROLE:?--role required}"
: "${SCOPE:?--scope required}"
: "${OID:?--oid required}"

# Best-effort lookup of role definition ID (Reader on the scope is enough).
ROLE_ID=$(az role definition list --name "$ROLE" --query "[0].name" -o tsv 2>/dev/null || true)
ROLE_ID="${ROLE_ID:-<unknown>}"

cat <<EOF

### 🔐 Action required: ${ACTION:-grant-role}

| Field | Value |
|---|---|
| Persona | $PERSONA |
| Required role | \`$ROLE\` |
| Role ID | \`$ROLE_ID\` |
| Scope | \`$SCOPE\` |
| Granted to (object id) | \`$OID\` |
| Why | $WHY |
| Expected duration | 5–15 min for RBAC propagation after grant |
| Verify with | \`az role assignment list --assignee $OID --scope "$SCOPE" --query "[?roleDefinitionName=='$ROLE']" -o table\` |

**Exact command for the assignee to run:**

\`\`\`bash
az role assignment create \\
  --assignee-object-id $OID \\
  --assignee-principal-type User \\
  --role "$ROLE" \\
  --scope "$SCOPE"
\`\`\`

**Then notify the requester** so they can re-run the skillpack step (after the 5–15 min propagation window).

EOF
