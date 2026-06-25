#!/usr/bin/env bash
# Manifest-aware guard wrapper for `azd ai agent init`. Reads
# agent-capabilities.yaml and threads the right flags so the init step
# scaffolds the path the manifest declared.
#
# Fixes:
#   FB-15 — Validate agent.yaml schema (AgentManifest vs ContainerAgent)
#           BEFORE running init, so we don't leave orphan state mid-init.
#   FB-20 — Pass --location <target.location> explicitly so init doesn't
#           infer from the resource group.
#   FB-21 — Fork on deploy_mode and pass --deploy-mode + --runtime +
#           --entry-point + --dep-resolution when manifest says `code`. The
#           old script was a transparent passthrough and silently scaffolded
#           the container path when the prompt forgot to pass the flag.
#
# Hazards (carried forward from v0.26):
#   1. Existing .git — informational
#   2. Existing azure.yaml — idempotent skip
#   3. Existing agent files — require --src or block
#
# Usage:
#   ./safe-azd-init.sh <agent_path> [extra-azd-init-flags...]
#
#   The script auto-derives --manifest, --src, --model-deployment,
#   --protocol, --deploy-mode, --runtime, --entry-point, --dep-resolution,
#   and --location from <agent_path>/agent-capabilities.yaml. Extra flags
#   passed on the CLI take precedence over derived values.
#
# Exit codes:
#   0 — azd init ran successfully (or was skipped because azure.yaml exists)
#   1 — hazard detected; user must confirm or resolve (CLOBBER_RISK or BLOCKED)
#   2 — azd init failed for another reason
#   4 — manifest missing required fields (e.g. target.location, model.deployment)
#   5 — agent.yaml schema mismatch (would fail init partway)
set -euo pipefail

AGENT_PATH="${1:?usage: $0 <agent_path> [extra-azd-init-flags...]}"
shift
EXTRA_FLAGS=("$@")

WORKSPACE_ROOT="$(pwd)"
MANIFEST="$AGENT_PATH/agent-capabilities.yaml"
AGENT_YAML="$AGENT_PATH/agent.yaml"
# Prefer a dedicated AgentManifest file (agent.manifest.yaml) when present — that is the
# schema `azd ai agent init --manifest` consumes. The agent-framework + langgraph-byo
# templates ship it alongside the (informational) ContainerAgent agent.yaml. Falling back
# to agent.yaml only when no manifest file exists keeps older single-file scaffolds working.
MANIFEST_YAML="$AGENT_PATH/agent.manifest.yaml"
if [[ -f "$MANIFEST_YAML" ]]; then
  INIT_MANIFEST="$MANIFEST_YAML"
else
  INIT_MANIFEST="$AGENT_YAML"
fi

# --------------------------------------------------------------------------
# 0. Read manifest (deploy_mode, model, location, code.*).
# --------------------------------------------------------------------------
read_yaml() {
  local file="$1" path="$2"
  if command -v yq >/dev/null 2>&1; then
    yq -r "$path // \"\"" "$file" 2>/dev/null || echo ""
  else
    python3 -c "
import yaml
with open('$file') as f: d = yaml.safe_load(f) or {}
keys = '''$path'''.lstrip('.').split('.')
v = d
for k in keys:
    if not isinstance(v, dict): v = ''; break
    v = v.get(k, '')
print(v if v is not None else '')
" 2>/dev/null
  fi
}

DEPLOY_MODE=""
MODEL_DEPLOYMENT=""
PROTOCOL=""
LOCATION=""
CODE_RUNTIME=""
CODE_ENTRY_POINT=""
CODE_DEP_RESOLUTION=""

if [[ -f "$MANIFEST" ]]; then
  DEPLOY_MODE="$(read_yaml "$MANIFEST" '.deploy_mode')"
  MODEL_DEPLOYMENT="$(read_yaml "$MANIFEST" '.model.deployment')"
  PROTOCOL="$(read_yaml "$MANIFEST" '.code.protocol')"
  LOCATION="$(read_yaml "$MANIFEST" '.target.location')"
  CODE_RUNTIME="$(read_yaml "$MANIFEST" '.code.runtime')"
  CODE_ENTRY_POINT="$(read_yaml "$MANIFEST" '.code.entry_point')"
  CODE_DEP_RESOLUTION="$(read_yaml "$MANIFEST" '.code.dependency_resolution')"
fi
[[ -z "$DEPLOY_MODE" ]] && DEPLOY_MODE="container"  # historic default
[[ -z "$PROTOCOL"   ]] && PROTOCOL="responses"

# Flag-override detection: if the caller passed an explicit value for a
# derived flag, respect it. Only auto-derive when the flag is absent.
has_flag() {
  local needle="$1"
  for arg in "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}"; do
    [[ "$arg" == "$needle" ]] && return 0
  done
  return 1
}

# --------------------------------------------------------------------------
# 1. Schema validation (FB-15). agent.yaml must be AgentManifest shape
#    (with a 'template:' wrapper) when we are going to pass --manifest.
# --------------------------------------------------------------------------
if [[ -f "$INIT_MANIFEST" ]]; then
  if command -v yq >/dev/null 2>&1; then
    HAS_TEMPLATE="$(yq -r '.template // ""' "$INIT_MANIFEST" 2>/dev/null)"
    KIND_TOP="$(yq -r '.kind // ""' "$INIT_MANIFEST" 2>/dev/null)"
  else
    HAS_TEMPLATE="$(python3 -c "
import yaml
with open('$INIT_MANIFEST') as f: d = yaml.safe_load(f) or {}
print(d.get('template') or '')" 2>/dev/null)"
    KIND_TOP="$(python3 -c "
import yaml
with open('$INIT_MANIFEST') as f: d = yaml.safe_load(f) or {}
print(d.get('kind') or '')" 2>/dev/null)"
  fi
  if [[ -z "$HAS_TEMPLATE" && -n "$KIND_TOP" ]]; then
    {
      echo "[x] $INIT_MANIFEST is ContainerAgent schema (top-level 'kind:'),"
      echo "    but \`azd ai agent init --manifest\` expects AgentManifest schema"
      echo "    (with a 'template:' wrapper)."
      echo
      echo "    See foundry-deploy/templates/langgraph-byo/agent.manifest.yaml.template"
      echo "    for the correct shape. /plan-agent v0.27.0 emits both schemas."
    } >&2
    echo "SAFE_AZD_INIT=schema-mismatch"
    echo "AGENT_YAML_SCHEMA=ContainerAgent"
    echo "EXPECTED_SCHEMA=AgentManifest"
    exit 5
  fi
fi

# --------------------------------------------------------------------------
# 2. Hazard checks (carried forward, slightly tightened).
# --------------------------------------------------------------------------
if [[ -d "$WORKSPACE_ROOT/.git" ]]; then
  echo "[i] .git exists at workspace root — azd init may try to reinitialize." >&2
fi

if [[ -f "$WORKSPACE_ROOT/azure.yaml" ]]; then
  echo "[✓] azure.yaml already exists. Skipping azd ai agent init (idempotent)." >&2
  echo "SAFE_AZD_INIT=skipped"
  echo "AZURE_YAML=exists"
  echo "DEPLOY_MODE=$DEPLOY_MODE"
  exit 0
fi

CLOBBER_FILES=()
for f in main.py Dockerfile requirements.txt; do
  if [[ -f "$AGENT_PATH/$f" ]]; then
    CLOBBER_FILES+=("$AGENT_PATH/$f")
  fi
done

# deploy_mode: code MUST NOT have a Dockerfile (would confuse azd's auto-detect)
if [[ "$DEPLOY_MODE" == "code" && -f "$AGENT_PATH/Dockerfile" ]]; then
  echo "[x] deploy_mode: code MUST NOT have a Dockerfile at $AGENT_PATH/Dockerfile." >&2
  echo "    Remove it before running azd ai agent init." >&2
  echo "SAFE_AZD_INIT=dockerfile-conflict"
  exit 1
fi

if (( ${#CLOBBER_FILES[@]} > 0 )); then
  echo "[!] azd ai agent init may overwrite these existing files:" >&2
  for f in "${CLOBBER_FILES[@]}"; do
    echo "    - $f" >&2
  done
  echo "SAFE_AZD_INIT=clobber-risk"
  echo "CLOBBER_FILES=${CLOBBER_FILES[*]}"

  if ! has_flag --src; then
    echo "[i] No --src flag; adding --src $AGENT_PATH so existing files are respected." >&2
  fi
fi

# --------------------------------------------------------------------------
# 3. Assemble the canonical flag set from manifest. Caller overrides win.
# --------------------------------------------------------------------------
DERIVED_FLAGS=()

if ! has_flag --manifest && [[ -f "$INIT_MANIFEST" ]]; then
  DERIVED_FLAGS+=(--manifest "$INIT_MANIFEST")
fi
if ! has_flag --src; then
  DERIVED_FLAGS+=(--src "$AGENT_PATH")
fi
if ! has_flag --model-deployment && [[ -n "$MODEL_DEPLOYMENT" ]]; then
  DERIVED_FLAGS+=(--model-deployment "$MODEL_DEPLOYMENT")
fi
if ! has_flag --protocol; then
  DERIVED_FLAGS+=(--protocol "$PROTOCOL")
fi
if ! has_flag --location && [[ -n "$LOCATION" ]]; then
  # FB-20: pass project location explicitly so init doesn't infer from RG.
  # F-H (2026-06): `azd ai agent init` removed `--location` in azd.ai.agents >= 0.1.41.
  # Only pass the flag if this azd build still accepts it; otherwise persist the location to
  # the azd environment (where current builds read it from) so init doesn't prompt/misinfer.
  if azd ai agent init --help 2>/dev/null | grep -q -- '--location'; then
    DERIVED_FLAGS+=(--location "$LOCATION")
  else
    azd env set AZURE_LOCATION "$LOCATION" >/dev/null 2>&1 || true
    echo "[i] azd ai agent init no longer takes --location; set AZURE_LOCATION=$LOCATION in azd env instead." >&2
  fi
fi

# FB-21: fork on deploy_mode and pass code-specific flags.
if [[ "$DEPLOY_MODE" == "code" ]]; then
  if ! has_flag --deploy-mode; then
    DERIVED_FLAGS+=(--deploy-mode code)
  fi
  if ! has_flag --runtime && [[ -n "$CODE_RUNTIME" ]]; then
    DERIVED_FLAGS+=(--runtime "$CODE_RUNTIME")
  fi
  if ! has_flag --entry-point && [[ -n "$CODE_ENTRY_POINT" ]]; then
    DERIVED_FLAGS+=(--entry-point "$CODE_ENTRY_POINT")
  fi
  if ! has_flag --dep-resolution && [[ -n "$CODE_DEP_RESOLUTION" ]]; then
    DERIVED_FLAGS+=(--dep-resolution "$CODE_DEP_RESOLUTION")
  fi

  # Required fields for code-deploy. If any are still missing, refuse.
  if [[ -z "$CODE_RUNTIME" || -z "$CODE_ENTRY_POINT" || -z "$CODE_DEP_RESOLUTION" ]]; then
    {
      echo "[x] deploy_mode: code requires code.runtime, code.entry_point, code.dependency_resolution"
      echo "    in $MANIFEST. Currently:"
      echo "      code.runtime: ${CODE_RUNTIME:-<empty>}"
      echo "      code.entry_point: ${CODE_ENTRY_POINT:-<empty>}"
      echo "      code.dependency_resolution: ${CODE_DEP_RESOLUTION:-<empty>}"
    } >&2
    echo "SAFE_AZD_INIT=manifest-incomplete"
    exit 4
  fi
fi

# --------------------------------------------------------------------------
# 4. Run init.
# --------------------------------------------------------------------------
ALL_FLAGS=("${DERIVED_FLAGS[@]+"${DERIVED_FLAGS[@]}"}" "${EXTRA_FLAGS[@]+"${EXTRA_FLAGS[@]}"}")

{
  echo "[+] Running: azd ai agent init \\"
  for ((i=0; i<${#ALL_FLAGS[@]}; i+=2)); do
    if (( i+1 < ${#ALL_FLAGS[@]} )); then
      echo "    ${ALL_FLAGS[i]} ${ALL_FLAGS[i+1]} \\"
    else
      echo "    ${ALL_FLAGS[i]}"
    fi
  done
} >&2

echo "DEPLOY_MODE=$DEPLOY_MODE"
echo "MODEL_DEPLOYMENT=$MODEL_DEPLOYMENT"
echo "LOCATION=$LOCATION"

if azd ai agent init "${ALL_FLAGS[@]}" 2>&1; then
  echo "SAFE_AZD_INIT=success"
  echo "AZURE_YAML=created"
  echo "[✓] azd ai agent init completed." >&2
  exit 0
else
  echo "SAFE_AZD_INIT=failed"
  echo "[x] azd ai agent init failed. Run validate-azure-yaml.sh after fixing." >&2
  exit 2
fi
