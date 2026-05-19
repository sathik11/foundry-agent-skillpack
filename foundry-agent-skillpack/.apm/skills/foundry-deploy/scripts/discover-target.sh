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
  # Pick first account; list all if multiple
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
    echo "[i] Using '$ACCT_NAME' (first). Override by passing to the prompt." >&2
  fi

  # --- 2. Project under the account ---
  echo "[i] Discovering project under $ACCT_NAME..." >&2
  # Projects are sub-resources: Microsoft.CognitiveServices/accounts/<name>/projects
  PROJECTS_JSON=$(az rest --method GET \
    --url "https://management.azure.com$ACCT_ID/projects?api-version=2024-10-01" \
    2>/dev/null || echo '{"value":[]}')
  PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq '.value | length')

  if (( PROJ_COUNT == 0 )); then
    echo "[x] No projects found under $ACCT_NAME." >&2
    echo "PROJECT_NAME="
  else
    PROJ_NAME=$(echo "$PROJECTS_JSON" | jq -r '.value[0].name')
    PROJ_ID=$(echo "$PROJECTS_JSON" | jq -r '.value[0].id')
    echo "PROJECT_NAME=$PROJ_NAME"
    echo "PROJECT_ID=$PROJ_ID"
    FOUND=$((FOUND + 1))

    if (( PROJ_COUNT > 1 )); then
      echo "[i] Multiple projects found ($PROJ_COUNT). Listing all:" >&2
      for i in $(seq 0 $((PROJ_COUNT - 1))); do
        N=$(echo "$PROJECTS_JSON" | jq -r ".value[$i].name")
        echo "  $((i+1)). $N" >&2
        echo "PROJECT_NAME_$((i+1))=$N"
      done
      echo "[i] Using '$PROJ_NAME' (first). Override by passing to the prompt." >&2
    fi

    # --- 3. Model deployments under the account ---
    echo "[i] Discovering model deployments under $ACCT_NAME..." >&2
    DEPLOYS_JSON=$(az cognitiveservices account deployment list \
      -g "$RG" -n "$ACCT_NAME" --subscription "$SUB" -o json 2>/dev/null || echo "[]")
    DEPLOY_COUNT=$(echo "$DEPLOYS_JSON" | jq 'length')

    if (( DEPLOY_COUNT == 0 )); then
      echo "[x] No model deployments found under $ACCT_NAME." >&2
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
      FOUND=$((FOUND + 1))

      if (( DEPLOY_COUNT > 1 )); then
        echo "[i] Multiple deployments found ($DEPLOY_COUNT). Listing all:" >&2
        for i in $(seq 0 $((DEPLOY_COUNT - 1))); do
          DN=$(echo "$DEPLOYS_JSON" | jq -r ".[$i].name")
          DM=$(echo "$DEPLOYS_JSON" | jq -r ".[$i].properties.model.name // \"?\"")
          echo "  $((i+1)). $DN (model: $DM)" >&2
          echo "MODEL_DEPLOYMENT_NAME_$((i+1))=$DN"
        done
        echo "[i] Using '$DEP_NAME' (first). Override via agent-capabilities.yaml model.deployment_name." >&2
      fi
    fi
  fi
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
