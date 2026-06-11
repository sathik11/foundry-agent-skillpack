#!/usr/bin/env bash
# Validate that the generated azure.yaml matches the deploy_mode declared in
# agent-capabilities.yaml BEFORE running `azd up` / `azd deploy`. FB-21 fix.
#
# The trap this catches: `azd ai agent init` was run without --deploy-mode code
# despite manifest declaring deploy_mode: code, so it scaffolded the container
# path. `azd provision` succeeds (real cloud resources burned), then `azd deploy`
# dies on missing Dockerfile / wrong language. This validator runs immediately
# after safe-azd-init.sh succeeds.
#
# Checks:
#   1. services.<svc>.language == "py" (or dotnetcore) when deploy_mode: code
#   2. services.<svc>.language == "docker" when deploy_mode: container
#   3. Dockerfile presence matches expected language
#   4. No orphan services.<svc>.docker block when language is py/dotnetcore
#
# Usage:
#   ./validate-azure-yaml.sh <agent_path>
#
# Exit codes:
#   0 — azure.yaml matches manifest; AZURE_YAML_VALID=true
#   2 — mismatch; RECOVERY=... emitted (caller STOPS)
#   3 — azure.yaml not found (init did not run)
#   4 — manifest missing required fields
set -euo pipefail

AGENT_PATH="${1:?usage: $0 <agent_path>}"
MANIFEST="$AGENT_PATH/agent-capabilities.yaml"
AZURE_YAML="./azure.yaml"

if [[ ! -f "$MANIFEST" ]]; then
  echo "[x] Missing manifest: $MANIFEST" >&2
  exit 4
fi

if [[ ! -f "$AZURE_YAML" ]]; then
  echo "[x] azure.yaml not found at repo root — has azd ai agent init run?" >&2
  exit 3
fi

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
    if isinstance(v, list):
        try: k = int(k)
        except: v = ''; break
        if k < 0 or k >= len(v): v = ''; break
        v = v[k]; continue
    if not isinstance(v, dict): v = ''; break
    v = v.get(k, '')
print(v if v is not None else '')
" 2>/dev/null
  fi
}

DEPLOY_MODE="$(read_yaml "$MANIFEST" '.deploy_mode')"
[[ -z "$DEPLOY_MODE" ]] && DEPLOY_MODE="container"

CODE_RUNTIME="$(read_yaml "$MANIFEST" '.code.runtime')"

# azure.yaml services map — pick first service name
if command -v yq >/dev/null 2>&1; then
  SVC_NAME="$(yq -r '.services | keys | .[0] // ""' "$AZURE_YAML" 2>/dev/null || echo "")"
else
  SVC_NAME="$(python3 -c "
import yaml
with open('$AZURE_YAML') as f: d = yaml.safe_load(f) or {}
svc = d.get('services') or {}
names = list(svc.keys()) if isinstance(svc, dict) else []
print(names[0] if names else '')
" 2>/dev/null)"
fi

if [[ -z "$SVC_NAME" ]]; then
  echo "[x] azure.yaml has no services entry" >&2
  echo "AZURE_YAML_VALID=false"
  exit 2
fi

ACTUAL_LANG="$(read_yaml "$AZURE_YAML" ".services.$SVC_NAME.language")"
ACTUAL_HOST="$(read_yaml "$AZURE_YAML" ".services.$SVC_NAME.host")"

# Determine EXPECTED language from manifest deploy_mode + code.runtime
case "$DEPLOY_MODE" in
  container)
    EXPECTED_LANG="docker"
    ;;
  code)
    case "$CODE_RUNTIME" in
      python_3_13|python_3_14|"")  EXPECTED_LANG="py" ;;
      dotnet_10|dotnet_*)          EXPECTED_LANG="dotnetcore" ;;
      *)                           EXPECTED_LANG="py" ;;
    esac
    ;;
  *)
    echo "[x] Unknown deploy_mode: $DEPLOY_MODE" >&2
    exit 4
    ;;
esac

echo "AZURE_YAML_FILE=$AZURE_YAML"
echo "AZURE_YAML_SERVICE=$SVC_NAME"
echo "AZURE_YAML_HOST=$ACTUAL_HOST"
echo "DEPLOY_MODE=$DEPLOY_MODE"
echo "EXPECTED_LANGUAGE=$EXPECTED_LANG"
echo "ACTUAL_LANGUAGE=$ACTUAL_LANG"

DOCKERFILE_PRESENT="false"
[[ -f "$AGENT_PATH/Dockerfile" ]] && DOCKERFILE_PRESENT="true"
echo "DOCKERFILE_PRESENT=$DOCKERFILE_PRESENT"

FAIL=0
RECOVERIES=()

# Check 1: language matches deploy_mode
if [[ "$ACTUAL_LANG" != "$EXPECTED_LANG" ]]; then
  FAIL=1
  RECOVERIES+=("Patch azure.yaml: services.${SVC_NAME}.language: $EXPECTED_LANG (currently: $ACTUAL_LANG)")
fi

# Check 2: Dockerfile presence matches
if [[ "$EXPECTED_LANG" == "docker" && "$DOCKERFILE_PRESENT" != "true" ]]; then
  FAIL=1
  RECOVERIES+=("deploy_mode: container requires $AGENT_PATH/Dockerfile — re-run /plan-agent Track A/B-Container")
fi
if [[ "$EXPECTED_LANG" != "docker" && "$DOCKERFILE_PRESENT" == "true" ]]; then
  FAIL=1
  RECOVERIES+=("deploy_mode: code MUST NOT have a Dockerfile — remove $AGENT_PATH/Dockerfile")
fi

# Check 3: orphan docker block on a code-deploy service
if [[ "$EXPECTED_LANG" != "docker" ]]; then
  HAS_DOCKER_BLOCK="$(read_yaml "$AZURE_YAML" ".services.$SVC_NAME.docker.path")"
  if [[ -n "$HAS_DOCKER_BLOCK" ]]; then
    FAIL=1
    RECOVERIES+=("Remove orphan services.${SVC_NAME}.docker block from azure.yaml — code-deploy does not use it")
  fi
fi

if (( FAIL == 0 )); then
  echo "AZURE_YAML_VALID=true"
  echo "[✓] azure.yaml matches deploy_mode: $DEPLOY_MODE (language: $ACTUAL_LANG)" >&2
  exit 0
fi

echo "AZURE_YAML_VALID=false"
{
  echo "[x] azure.yaml does not match manifest deploy_mode: $DEPLOY_MODE"
  for r in "${RECOVERIES[@]}"; do
    echo "    - $r"
  done
  echo
  echo "[i] Permanent fix: delete azure.yaml + .azure/ + infra/, then re-run"
  echo "    /prepare-deploy — safe-azd-init.sh will pass --deploy-mode $DEPLOY_MODE this time."
} >&2

# Emit recoveries as KV so the prompt can render them in a structured way
i=1
for r in "${RECOVERIES[@]}"; do
  echo "RECOVERY_${i}=$r"
  i=$((i + 1))
done

exit 2
