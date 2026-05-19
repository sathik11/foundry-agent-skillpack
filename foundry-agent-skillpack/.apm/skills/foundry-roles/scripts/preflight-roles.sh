#!/usr/bin/env bash
# Batch role preflight — checks all roles a prompt step needs in one call.
#
# Instead of N sequential preflight-role.sh calls, this takes a prompt name
# and knows what roles+scopes are needed. Single script, one output.
#
# Usage:
#   ./preflight-roles.sh <prompt_name> <subscription_id> <resource_group> [<foundry_account> <project>]
#
# prompt_name is one of:
#   plan-agent       — needs Reader on RG + Azure AI User on project
#   prepare-deploy   — needs Contributor on RG + Azure AI Developer on project
#   configure-rbac   — needs User Access Administrator on RG (or Owner)
#   setup-evals      — needs Azure AI User on project
#   publish-teams    — needs Azure AI Developer on project
#
# Output (stdout, KEY=VALUE):
#   PREFLIGHT_PROMPT=<prompt_name>
#   PREFLIGHT_RESULT=pass|partial|fail
#   PREFLIGHT_PASS_COUNT=N
#   PREFLIGHT_TOTAL_COUNT=N
#   PREFLIGHT_MISSING=<role1>@<scope1>,<role2>@<scope2>,...  (empty if all pass)
#
# Human-readable progress goes to stderr. Runbooks for missing roles are
# emitted to stdout after the KEY=VALUE block (so the agent can show them).
#
# Exit codes:
#   0 — all roles present
#   1 — one or more roles missing (runbooks emitted)
#   2 — couldn't determine (e.g., no Reader on a scope)
set -euo pipefail

PROMPT="${1:?usage: $0 <prompt_name> <sub> <rg> [<account> <project>]}"
SUB="${2:?usage: $0 <prompt_name> <sub> <rg> [<account> <project>]}"
RG="${3:?usage: $0 <prompt_name> <sub> <rg> [<account> <project>]}"
ACCOUNT="${4:-}"
PROJECT="${5:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RG_SCOPE="/subscriptions/$SUB/resourceGroups/$RG"
ACCOUNT_SCOPE=""
PROJECT_SCOPE=""
if [[ -n "$ACCOUNT" ]]; then
  ACCOUNT_SCOPE="$RG_SCOPE/providers/Microsoft.CognitiveServices/accounts/$ACCOUNT"
fi
if [[ -n "$ACCOUNT" && -n "$PROJECT" ]]; then
  PROJECT_SCOPE="$ACCOUNT_SCOPE/projects/$PROJECT"
fi

# Build the role check list based on prompt name
declare -a CHECKS=()  # Each entry: "role|scope|why"

case "$PROMPT" in
  plan-agent)
    CHECKS+=(
      "Reader|$RG_SCOPE|plan-agent needs to enumerate resources in the RG"
    )
    if [[ -n "$PROJECT_SCOPE" ]]; then
      CHECKS+=("Azure AI User|$PROJECT_SCOPE|plan-agent needs to read model deployments")
    fi
    ;;
  prepare-deploy)
    CHECKS+=(
      "Contributor|$RG_SCOPE|prepare-deploy needs Contributor for azd up"
    )
    if [[ -n "$PROJECT_SCOPE" ]]; then
      CHECKS+=("Azure AI Developer|$PROJECT_SCOPE|prepare-deploy needs Azure AI Developer for agent management")
    fi
    ;;
  configure-rbac)
    CHECKS+=(
      "User Access Administrator|$RG_SCOPE|configure-rbac needs to create role assignments"
    )
    ;;
  setup-evals)
    if [[ -n "$PROJECT_SCOPE" ]]; then
      CHECKS+=("Azure AI User|$PROJECT_SCOPE|setup-evals needs to create eval rules in the project")
    fi
    ;;
  publish-teams)
    if [[ -n "$PROJECT_SCOPE" ]]; then
      CHECKS+=("Azure AI Developer|$PROJECT_SCOPE|publish-teams needs to read agent config")
    fi
    ;;
  *)
    echo "[x] Unknown prompt: $PROMPT" >&2
    echo "    Known prompts: plan-agent, prepare-deploy, configure-rbac, setup-evals, publish-teams" >&2
    exit 64
    ;;
esac

echo "PREFLIGHT_PROMPT=$PROMPT"

# Get caller's identity once
CALLER_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
if [[ -z "$CALLER_OID" ]]; then
  echo "[x] Not logged in to az. Run 'az login' first." >&2
  echo "PREFLIGHT_RESULT=fail"
  echo "PREFLIGHT_PASS_COUNT=0"
  echo "PREFLIGHT_TOTAL_COUNT=${#CHECKS[@]}"
  exit 2
fi

PASS=0
TOTAL=${#CHECKS[@]}
MISSING=()
RUNBOOKS=""

for check in "${CHECKS[@]}"; do
  IFS='|' read -r ROLE SCOPE WHY <<< "$check"

  echo "[i] Checking: $ROLE @ $(basename "$SCOPE")..." >&2

  # Use preflight-role.sh but capture its output instead of letting it exit
  RUNBOOK_OUTPUT=""
  if RUNBOOK_OUTPUT=$("$SCRIPT_DIR/preflight-role.sh" "$ROLE" "$SCOPE" \
    --persona "DevOps" --why "$WHY" --action "$PROMPT" 2>&1); then
    PASS=$((PASS + 1))
    echo "  [✓] $ROLE" >&2
  else
    RC=$?
    MISSING+=("${ROLE}@$(basename "$SCOPE")")
    echo "  [x] Missing: $ROLE" >&2
    if [[ -n "$RUNBOOK_OUTPUT" ]]; then
      RUNBOOKS+="$RUNBOOK_OUTPUT"$'\n\n'
    fi
  fi
done

echo "PREFLIGHT_PASS_COUNT=$PASS"
echo "PREFLIGHT_TOTAL_COUNT=$TOTAL"

if (( PASS == TOTAL )); then
  echo "PREFLIGHT_RESULT=pass"
  echo "PREFLIGHT_MISSING="
  echo "[✓] All $TOTAL role checks passed for /$PROMPT." >&2
  exit 0
else
  MISSING_STR=$(IFS=','; echo "${MISSING[*]}")
  echo "PREFLIGHT_MISSING=$MISSING_STR"

  if (( PASS == 0 )); then
    echo "PREFLIGHT_RESULT=fail"
  else
    echo "PREFLIGHT_RESULT=partial"
  fi

  echo "[x] $((TOTAL - PASS))/$TOTAL role(s) missing for /$PROMPT." >&2
  echo >&2

  # Emit runbooks after KEY=VALUE block
  if [[ -n "$RUNBOOKS" ]]; then
    echo "$RUNBOOKS"
  fi

  exit 1
fi
