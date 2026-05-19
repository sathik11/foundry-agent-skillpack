#!/usr/bin/env bash
# Auto-select a model deployment. No interactive picklist.
#
# Logic:
#   1. If a deployment_name hint is given and it exists → use it.
#   2. If only one deployment exists → auto-select it.
#   3. If multiple exist → pick the first that supports agentsV2.
#   4. If none match → list all and exit 1 (caller must specify).
#
# Usage:
#   ./select-model.sh <subscription_id> <resource_group> <foundry_account> [<deployment_name_hint>]
#
# Output (stdout, KEY=VALUE):
#   MODEL_DEPLOYMENT_NAME=...
#   MODEL_NAME=...
#   MODEL_VERSION=...
#   MODEL_FORMAT=...
#   MODEL_AGENTS_CAPABLE=true|false
#   MODEL_SELECTION_METHOD=hint|auto-single|auto-agents|manual-needed
set -euo pipefail

SUB="${1:?usage: $0 <sub> <rg> <account> [<deployment_hint>]}"
RG="${2:?usage: $0 <sub> <rg> <account> [<deployment_hint>]}"
ACCOUNT="${3:?usage: $0 <sub> <rg> <account> [<deployment_hint>]}"
HINT="${4:-}"

echo "[i] Listing model deployments under $ACCOUNT..." >&2
DEPLOYS=$(az cognitiveservices account deployment list \
  -g "$RG" -n "$ACCOUNT" --subscription "$SUB" -o json 2>/dev/null || echo "[]")

COUNT=$(echo "$DEPLOYS" | jq 'length')

if (( COUNT == 0 )); then
  echo "[x] No model deployments found under $ACCOUNT." >&2
  echo "MODEL_DEPLOYMENT_NAME="
  echo "MODEL_SELECTION_METHOD=manual-needed"
  exit 1
fi

# Helper: extract deployment info by index
dep_info() {
  local idx="$1"
  echo "$DEPLOYS" | jq -r --argjson i "$idx" '{
    name: .[$i].name,
    model: .[$i].properties.model.name,
    version: .[$i].properties.model.version,
    format: .[$i].properties.model.format,
    agents: ((.[$i].properties.capabilities.agentsV2 // "false") == "true")
  } | to_entries | map("\(.key)=\(.value)") | .[]'
}

emit() {
  local idx="$1" method="$2"
  local name model version format agents
  name=$(echo "$DEPLOYS" | jq -r ".[$idx].name")
  model=$(echo "$DEPLOYS" | jq -r ".[$idx].properties.model.name // \"unknown\"")
  version=$(echo "$DEPLOYS" | jq -r ".[$idx].properties.model.version // \"unknown\"")
  format=$(echo "$DEPLOYS" | jq -r ".[$idx].properties.model.format // \"unknown\"")
  agents=$(echo "$DEPLOYS" | jq -r "if (.[$idx].properties.capabilities.agentsV2 // \"false\") == \"true\" then \"true\" else \"false\" end")

  echo "MODEL_DEPLOYMENT_NAME=$name"
  echo "MODEL_NAME=$model"
  echo "MODEL_VERSION=$version"
  echo "MODEL_FORMAT=$format"
  echo "MODEL_AGENTS_CAPABLE=$agents"
  echo "MODEL_SELECTION_METHOD=$method"
  echo "[✓] Selected: $name (model: $model, agents: $agents) via $method" >&2
}

# Strategy 1: hint match
if [[ -n "$HINT" ]]; then
  for i in $(seq 0 $((COUNT - 1))); do
    N=$(echo "$DEPLOYS" | jq -r ".[$i].name")
    if [[ "$N" == "$HINT" ]]; then
      emit "$i" "hint"
      exit 0
    fi
  done
  echo "[!] Hint '$HINT' not found among $COUNT deployments. Trying auto-select..." >&2
fi

# Strategy 2: single deployment
if (( COUNT == 1 )); then
  emit 0 "auto-single"
  exit 0
fi

# Strategy 3: first agents-capable deployment
for i in $(seq 0 $((COUNT - 1))); do
  CAPABLE=$(echo "$DEPLOYS" | jq -r "if (.[$i].properties.capabilities.agentsV2 // \"false\") == \"true\" then \"true\" else \"false\" end")
  if [[ "$CAPABLE" == "true" ]]; then
    emit "$i" "auto-agents"
    exit 0
  fi
done

# Strategy 4: can't auto-select — list all for manual choice
echo "[!] $COUNT deployments found, none marked agentsV2-capable. Listing all:" >&2
for i in $(seq 0 $((COUNT - 1))); do
  N=$(echo "$DEPLOYS" | jq -r ".[$i].name")
  M=$(echo "$DEPLOYS" | jq -r ".[$i].properties.model.name // \"?\"")
  A=$(echo "$DEPLOYS" | jq -r ".[$i].properties.capabilities.agentsV2 // \"?\"")
  echo "  $((i+1)). $N (model: $M, agentsV2: $A)" >&2
  echo "MODEL_DEPLOYMENT_NAME_$((i+1))=$N"
done

echo "MODEL_DEPLOYMENT_NAME="
echo "MODEL_SELECTION_METHOD=manual-needed"
exit 1
