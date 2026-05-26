#!/usr/bin/env bash
# Discover Foundry target resources in a resource group.
# Single script that replaces scattered MCP calls + Resource Graph + inline python.
#
# Outputs KEY=VALUE pairs to stdout (machine-readable).
# Human context goes to stderr.
#
# Usage:
#   ./discover-target.sh <subscription_id> <resource_group>
#
# Output keys:
#   SUBSCRIPTION_ID, RESOURCE_GROUP
#   FOUNDRY_ACCOUNT_NAME, FOUNDRY_ACCOUNT_ID, FOUNDRY_ACCOUNT_KIND, FOUNDRY_ACCOUNT_LOCATION
#   PROJECT_NAME, PROJECT_ID
#   ACR_NAME, ACR_ID, ACR_LOGIN_SERVER
#   MODEL_DEPLOYMENT_NAME, MODEL_DEPLOYMENT_FORMAT, MODEL_NAME, MODEL_VERSION
#   DISCOVERY_STATUS  — "complete" if all 4 found, "partial" if some missing
#
# When multiple resources of a kind exist, all are listed (suffixed _1, _2, etc.)
# and the first is used for the un-suffixed key. The calling prompt can override.
set -euo pipefail

SUB="${1:?usage: $0 <subscription_id> <resource_group>}"
RG="${2:?usage: $0 <subscription_id> <resource_group>}"

echo "SUBSCRIPTION_ID=$SUB"
echo "RESOURCE_GROUP=$RG"

FOUND=0
TOTAL=4  # account, project, ACR, model

# --- 1. Foundry Account (CognitiveServices accounts) ---
echo "[i] Discovering Foundry account in $RG..." >&2
ACCOUNTS_JSON=$(az cognitiveservices account list -g "$RG" --subscription "$SUB" -o json 2>/dev/null || echo "[]")
ACCOUNT_COUNT=$(echo "$ACCOUNTS_JSON" | jq 'length')

if (( ACCOUNT_COUNT == 0 )); then
  echo "[x] No Foundry / Cognitive Services accounts found in $RG." >&2
  echo "FOUNDRY_ACCOUNT_NAME="
else
  # Primary account = first by jq order. Existing un-suffixed keys are emitted
  # from this account so downstream prompts keep working.
  ACCT_NAME=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].name')
  ACCT_ID=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].id')
  ACCT_KIND=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].kind')
  ACCT_LOC=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].location')
  echo "FOUNDRY_ACCOUNT_NAME=$ACCT_NAME"
  echo "FOUNDRY_ACCOUNT_ID=$ACCT_ID"
  echo "FOUNDRY_ACCOUNT_KIND=$ACCT_KIND"
  echo "FOUNDRY_ACCOUNT_LOCATION=$ACCT_LOC"
  FOUND=$((FOUND + 1))

  if (( ACCOUNT_COUNT > 1 )); then
    echo "[i] Multiple accounts found ($ACCOUNT_COUNT). Listing all:" >&2
    for i in $(seq 0 $((ACCOUNT_COUNT - 1))); do
      N=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].name")
      K=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].kind")
      echo "  $((i+1)). $N (kind: $K)" >&2
      echo "FOUNDRY_ACCOUNT_NAME_$((i+1))=$N"
    done
    echo "[i] Primary: '$ACCT_NAME'. Override by passing to the prompt." >&2
  fi

  # --- 2 & 3. Projects + deployments — enumerated PER AIServices account ---
  #
  # Previously: only account [0] was queried, so multi-account RGs silently
  # lost projects + deployments belonging to other accounts.
  # Now: loop over every AIServices account. Emit un-suffixed primary keys
  # from account [0] for contract compatibility, and per-account aggregate
  # keys (ACCOUNT_<n>_PROJECT_NAMES / ACCOUNT_<n>_DEPLOYMENT_NAMES) for the
  # rest so prompts can see the full surface.
  #
  # api-version: latest GA for Microsoft.CognitiveServices/accounts/projects
  # (verified via `az provider show -n Microsoft.CognitiveServices`).
  PROJECTS_API_VERSION="2026-03-01"

  any_project_found=0
  any_deployment_found=0

  for i in $(seq 0 $((ACCOUNT_COUNT - 1))); do
    A_NAME=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].name")
    A_ID=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].id")
    A_KIND=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].kind")

    # Projects + agent-facing deployments only exist on AIServices accounts.
    # Skip ContentSafety, OpenAI-only, etc.
    [[ "$A_KIND" != "AIServices" ]] && continue

    # --- Projects under this account ---
    # Capture stderr so an api-version drift surfaces instead of being swallowed.
    PROJ_RESP=$(az rest --method GET \
      --url "https://management.azure.com${A_ID}/projects?api-version=${PROJECTS_API_VERSION}" \
      2>&1) || PROJ_RC=$?
    PROJ_RC=${PROJ_RC:-0}
    if (( PROJ_RC != 0 )); then
      echo "[!] Projects API failed for $A_NAME (rc=$PROJ_RC). Bump api-version or check RBAC." >&2
      echo "    Response: $(echo "$PROJ_RESP" | head -c 240)" >&2
      PROJECTS_JSON='{"value":[]}'
    else
      PROJECTS_JSON="$PROJ_RESP"
    fi
    unset PROJ_RC
    PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq '.value | length')

    if (( i == 0 )); then
      if (( PROJ_COUNT == 0 )); then
        echo "[x] No projects under primary account $A_NAME." >&2
        echo "PROJECT_NAME="
      else
        PROJ_NAME=$(echo "$PROJECTS_JSON" | jq -r '.value[0].name')
        PROJ_ID=$(echo "$PROJECTS_JSON" | jq -r '.value[0].id')
        echo "PROJECT_NAME=$PROJ_NAME"
        echo "PROJECT_ID=$PROJ_ID"
        any_project_found=1
        if (( PROJ_COUNT > 1 )); then
          echo "[i] Account $A_NAME has $PROJ_COUNT projects:" >&2
          for j in $(seq 0 $((PROJ_COUNT - 1))); do
            N=$(echo "$PROJECTS_JSON" | jq -r ".value[$j].name")
            echo "  $((j+1)). $N" >&2
            echo "PROJECT_NAME_$((j+1))=$N"
          done
          echo "[i] Primary: '$PROJ_NAME'. Override via prompt." >&2
        fi
      fi
    else
      # Non-primary account: emit aggregate key + log
      if (( PROJ_COUNT > 0 )); then
        NAMES=$(echo "$PROJECTS_JSON" | jq -r '[.value[].name] | join(",")')
        echo "ACCOUNT_$((i+1))_PROJECT_NAMES=$NAMES"
        echo "[i] Account $((i+1)) ($A_NAME) has $PROJ_COUNT project(s): $NAMES" >&2
        any_project_found=1
      fi
    fi

    # --- Deployments under this account ---
    DEPLOYS_JSON=$(az cognitiveservices account deployment list \
      -g "$RG" -n "$A_NAME" --subscription "$SUB" -o json 2>/dev/null || echo "[]")
    DEPLOY_COUNT=$(echo "$DEPLOYS_JSON" | jq 'length')

    if (( i == 0 )); then
      if (( DEPLOY_COUNT == 0 )); then
        echo "[x] No model deployments under primary account $A_NAME." >&2
        echo "MODEL_DEPLOYMENT_NAME="
      else
        DEP_NAME=$(echo "$DEPLOYS_JSON" | jq -r '.[0].name')
        DEP_FORMAT=$(echo "$DEPLOYS_JSON" | jq -r '.[0].properties.model.format // "unknown"')
        DEP_MODEL=$(echo "$DEPLOYS_JSON" | jq -r '.[0].properties.model.name // "unknown"')
        DEP_VERSION=$(echo "$DEPLOYS_JSON" | jq -r '.[0].properties.model.version // "unknown"')
        echo "MODEL_DEPLOYMENT_NAME=$DEP_NAME"
        echo "MODEL_DEPLOYMENT_FORMAT=$DEP_FORMAT"
        echo "MODEL_NAME=$DEP_MODEL"
        echo "MODEL_VERSION=$DEP_VERSION"
        any_deployment_found=1
        if (( DEPLOY_COUNT > 1 )); then
          echo "[i] Account $A_NAME has $DEPLOY_COUNT deployments:" >&2
          for j in $(seq 0 $((DEPLOY_COUNT - 1))); do
            DN=$(echo "$DEPLOYS_JSON" | jq -r ".[$j].name")
            DM=$(echo "$DEPLOYS_JSON" | jq -r ".[$j].properties.model.name // \"?\"")
            echo "  $((j+1)). $DN (model: $DM)" >&2
            echo "MODEL_DEPLOYMENT_NAME_$((j+1))=$DN"
          done
          echo "[i] Primary: '$DEP_NAME'. Override via agent-capabilities.yaml model.deployment_name." >&2
        fi
      fi
    else
      if (( DEPLOY_COUNT > 0 )); then
        NAMES=$(echo "$DEPLOYS_JSON" | jq -r '[.[].name] | join(",")')
        echo "ACCOUNT_$((i+1))_DEPLOYMENT_NAMES=$NAMES"
        echo "[i] Account $((i+1)) ($A_NAME) has $DEPLOY_COUNT deployment(s): $NAMES" >&2
        any_deployment_found=1
      fi
    fi
  done

  (( any_project_found == 1 )) && FOUND=$((FOUND + 1))
  (( any_deployment_found == 1 )) && FOUND=$((FOUND + 1))
fi

# --- 4. ACR ---
echo "[i] Discovering ACR in $RG..." >&2
ACR_JSON=$(az acr list -g "$RG" --subscription "$SUB" -o json 2>/dev/null || echo "[]")
ACR_COUNT=$(echo "$ACR_JSON" | jq 'length')

if (( ACR_COUNT == 0 )); then
  echo "[x] No ACR found in $RG." >&2
  echo "ACR_NAME="
else
  ACR_N=$(echo "$ACR_JSON" | jq -r '.[0].name')
  ACR_I=$(echo "$ACR_JSON" | jq -r '.[0].id')
  ACR_L=$(echo "$ACR_JSON" | jq -r '.[0].loginServer')
  echo "ACR_NAME=$ACR_N"
  echo "ACR_ID=$ACR_I"
  echo "ACR_LOGIN_SERVER=$ACR_L"
  FOUND=$((FOUND + 1))

  if (( ACR_COUNT > 1 )); then
    echo "[i] Multiple ACRs found ($ACR_COUNT). Listing all:" >&2
    for i in $(seq 0 $((ACR_COUNT - 1))); do
      AN=$(echo "$ACR_JSON" | jq -r ".[$i].name")
      echo "  $((i+1)). $AN" >&2
      echo "ACR_NAME_$((i+1))=$AN"
    done
    echo "[i] Using '$ACR_N' (first). Override by passing to the prompt." >&2
  fi
fi

# --- Summary ---
if (( FOUND == TOTAL )); then
  echo "DISCOVERY_STATUS=complete"
  echo "[✓] All $TOTAL resources discovered." >&2
else
  echo "DISCOVERY_STATUS=partial"
  echo "[!] Discovered $FOUND/$TOTAL resources. Missing resources flagged above." >&2
fi
