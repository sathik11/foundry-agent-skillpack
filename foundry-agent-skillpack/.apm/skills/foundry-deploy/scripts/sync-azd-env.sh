#!/usr/bin/env bash
# Push agent-capabilities.yaml + cached topology into the local `azd` env
# in ONE approval (FB-16). Replaces the manual ~8 `azd env set` ceremony.
#
# Why this exists: `/prepare-deploy` was making the user run 8 separate
# `azd env set KEY=VALUE` lines, each as its own approval, even though
# every value was already authoritatively in agent-capabilities.yaml or
# in ./assessment/project-topology.json. This wrapper reads both files
# and runs all the `azd env set` calls non-interactively.
#
# Also handles the cross-region BYO contract (FB-20):
#   * Always reads AZURE_LOCATION from manifest target.location
#     (NOT from RG location, NOT from `azd ai agent init` inference).
#   * Sets USE_EXISTING_AI_PROJECT=true when both account + project are
#     populated — opts out of the Bicep that tries to create them.
#
# Usage:
#   ./sync-azd-env.sh <agent_path>
#
# Pre-requisite: `azd env select <env>` already done (or `azd init` ran).
#
# Exit codes:
#   0 — all sets succeeded; KV summary on stdout
#   2 — agent-capabilities.yaml not found
#   3 — `azd` not on PATH or no env selected
#   4 — manifest missing required target.* fields
set -euo pipefail

AGENT_PATH="${1:?usage: $0 <agent_path>}"
MANIFEST="$AGENT_PATH/agent-capabilities.yaml"
TOPOLOGY="./assessment/project-topology.json"

if [[ ! -f "$MANIFEST" ]]; then
  echo "[x] Missing manifest: $MANIFEST" >&2
  exit 2
fi

if ! command -v azd >/dev/null 2>&1; then
  echo "[x] azd CLI not on PATH" >&2
  exit 3
fi

if ! azd env get-name >/dev/null 2>&1; then
  echo "[x] No azd env selected. Run \`azd env new <name>\` or \`azd init\` first." >&2
  exit 3
fi

# yq is the canonical reader. Fall back to python+pyyaml if yq absent.
read_yaml() {
  local path="$1"
  if command -v yq >/dev/null 2>&1; then
    yq -r "$path // \"\"" "$MANIFEST" 2>/dev/null || echo ""
  else
    python3 -c "
import sys, yaml
with open('$MANIFEST') as f: d = yaml.safe_load(f) or {}
# Translate jq path '.a.b.c' to dict lookups
keys = '''$path'''.lstrip('.').split('.')
v = d
for k in keys:
    if not isinstance(v, dict): v = ''; break
    v = v.get(k, '')
print(v if v is not None else '')
" 2>/dev/null
  fi
}

SUB="$(read_yaml '.target.subscription_id')"
RG="$(read_yaml '.target.resource_group')"
LOC="$(read_yaml '.target.location')"
ACCT="$(read_yaml '.target.foundry_account')"
PROJ="$(read_yaml '.target.project')"
MODEL="$(read_yaml '.model.deployment')"
ACR="$(read_yaml '.target.acr_name')"
DEPLOY_MODE="$(read_yaml '.deploy_mode')"
[[ -z "$DEPLOY_MODE" ]] && DEPLOY_MODE="container"  # historic default

# Topology fallback for fields manifest doesn't carry yet
if [[ -z "$ACR" && -f "$TOPOLOGY" ]]; then
  ACR="$(jq -r '.acr.name // empty' "$TOPOLOGY" 2>/dev/null || echo "")"
fi

# Required: at minimum we need location and either (subscription+RG) or an existing project
if [[ -z "$LOC" ]]; then
  echo "[x] manifest.target.location is required but empty" >&2
  exit 4
fi

set_env() {
  local key="$1" value="$2"
  [[ -z "$value" ]] && return 0
  # azd env set is idempotent; suppress its noise but show our own line
  azd env set "$key" "$value" >/dev/null 2>&1 && echo "[+] azd env set ${key}=${value}" >&2
  echo "AZD_ENV_${key}=${value}"
}

# Core BYO target
set_env AZURE_LOCATION                  "$LOC"
set_env AZURE_SUBSCRIPTION_ID           "$SUB"
set_env AZURE_RESOURCE_GROUP            "$RG"
set_env AZURE_AI_FOUNDRY_NAME           "$ACCT"
set_env AZURE_AI_PROJECT_NAME           "$PROJ"
set_env AZURE_AI_MODEL_DEPLOYMENT_NAME  "$MODEL"

# Container path only
if [[ "$DEPLOY_MODE" == "container" && -n "$ACR" ]]; then
  set_env ACR_NAME "$ACR"
fi

# Cross-region BYO contract: if BOTH account + project are populated, the
# project already exists — don't let Bicep try to create it (FB-20 fix).
if [[ -n "$ACCT" && -n "$PROJ" ]]; then
  set_env USE_EXISTING_AI_PROJECT "true"
fi

echo "SYNC_AZD_ENV=ok"
echo "DEPLOY_MODE=$DEPLOY_MODE"
exit 0
