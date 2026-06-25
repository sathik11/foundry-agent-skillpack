#!/usr/bin/env bash
# One-approval wrapper for /prepare-deploy (FB-14). Chains the entire
# pre-`azd up` pipeline into a single tool call. Replaces the ~12 separate
# approvals in v0.26 with 1.
#
# Stages (run in order; first failure stops):
#   1. read-topology         — load cached project topology
#   2. preflight-azd         — azd/az version floors (FB-8, FB-9, FB-10, FB-17)
#   3. sync-azd-env          — push manifest values into azd env (FB-16)
#   4. safe-azd-init         — manifest-aware azd ai agent init (FB-15, FB-20, FB-21)
#   5. validate-azd-env-loc  — diff AZURE_LOCATION vs manifest (FB-20)
#   6. validate-azure-yaml   — language matches deploy_mode (FB-21)
#   7. stamp-status          — one atomic write to agent-status.json (FB-14)
#
# Outputs:
#   * stdout — composite KV stream + final PREPARE_DEPLOY=ok|failed
#   * stderr — human-readable progress
#   * <agent_path>/.preflight.kv — captured KV for /prepare-deploy Step 6
#   * <agent_path>/agent-status.json preflight section stamped
#
# Usage:
#   ./prepare-deploy.sh <agent_path>
#
# Exit codes:
#   0 — all stages ok, `azd up` is safe to run
#   2 — a stage failed; FAIL_STAGE + RECOVERY emitted on stdout; caller STOPS
#   3 — wrapper itself misconfigured (missing sibling script)
set -euo pipefail

AGENT_PATH="${1:?usage: $0 <agent_path>}"
MANIFEST="$AGENT_PATH/agent-capabilities.yaml"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READ_TOPOLOGY="$SCRIPT_DIR/read-topology.sh"
PREFLIGHT_AZD="$SCRIPT_DIR/preflight-azd.sh"
SYNC_AZD_ENV="$SCRIPT_DIR/sync-azd-env.sh"
SAFE_AZD_INIT="$SCRIPT_DIR/safe-azd-init.sh"
VAL_LOC="$SCRIPT_DIR/validate-azd-env-location.sh"
VAL_YAML="$SCRIPT_DIR/validate-azure-yaml.sh"
STATUS_PY="$SCRIPT_DIR/agent_status.py"

for f in "$READ_TOPOLOGY" "$PREFLIGHT_AZD" "$SYNC_AZD_ENV" "$SAFE_AZD_INIT" "$VAL_LOC" "$VAL_YAML" "$STATUS_PY"; do
  if [[ ! -r "$f" ]]; then
    echo "[x] Missing sibling: $f" >&2
    exit 3
  fi
done

if [[ ! -f "$MANIFEST" ]]; then
  echo "[x] No manifest at $MANIFEST — run /plan-agent first." >&2
  exit 2
fi

# Read deploy_mode once so we pass --deploy-mode to preflight-azd.
read_yaml() {
  local path="$1"
  if command -v yq >/dev/null 2>&1; then
    yq -r "$path // \"\"" "$MANIFEST" 2>/dev/null || echo ""
  else
    python3 -c "
import yaml
with open('$MANIFEST') as f: d = yaml.safe_load(f) or {}
keys = '''$path'''.lstrip('.').split('.')
v = d
for k in keys:
    if not isinstance(v, dict): v = ''; break
    v = v.get(k, '')
print(v if v is not None else '')
" 2>/dev/null
  fi
}
DEPLOY_MODE="$(read_yaml '.deploy_mode')"
[[ -z "$DEPLOY_MODE" ]] && DEPLOY_MODE="container"

# Collect all stages' KV into one JSON blob for a single stamp.
KV_DIR="$(mktemp -d -t prepare-deploy.XXXXXX)"
trap 'rm -rf "$KV_DIR"' EXIT

run_stage() {
  # run_stage <name> <command...>
  local name="$1"; shift
  local kv_file="$KV_DIR/$name.kv"
  local err_file="$KV_DIR/$name.stderr"
  echo "" >&2
  echo "──── $name ────" >&2
  # Capture the stage exit code RELIABLY. A previous version used
  #   if "$@" 2> >(tee ...); then ... fi; local rc=$?
  # but the process-substitution clobbers $? before `local rc=$?`, so a real
  # non-zero stage was reported as FAIL_EXIT_CODE=0 (masking the true error).
  # Use a plain stderr file + tee afterwards so $? reflects "$@" exactly.
  "$@" >"$kv_file" 2>"$err_file"
  local rc=$?
  tee -a "$KV_DIR/stderr.log" < "$err_file" >&2
  if [[ $rc -eq 0 ]]; then
    cat "$kv_file"          # forward this stage's KV to our stdout
    echo "STAGE_${name//-/_}=ok"
    return 0
  fi
  cat "$kv_file"            # forward partial KV on failure too
  echo "STAGE_${name//-/_}=failed"
  echo "FAIL_STAGE=$name"
  echo "FAIL_EXIT_CODE=$rc"
  # Surface RECOVERY if the stage emitted one
  if grep -q '^RECOVERY=' "$kv_file"; then
    grep '^RECOVERY' "$kv_file" | head -1
  fi
  echo "PREPARE_DEPLOY=failed"
  exit 2
}

run_stage read-topology         "$READ_TOPOLOGY"                  || true   # missing topology is OK (warn, don't block)
run_stage preflight-azd         "$PREFLIGHT_AZD" --deploy-mode "$DEPLOY_MODE"
run_stage sync-azd-env          "$SYNC_AZD_ENV" "$AGENT_PATH"
run_stage safe-azd-init         "$SAFE_AZD_INIT" "$AGENT_PATH"
run_stage validate-azd-env-loc  "$VAL_LOC" "$AGENT_PATH"
run_stage validate-azure-yaml   "$VAL_YAML" "$AGENT_PATH"

# ── stamp ────────────────────────────────────────────────────────────────
# Build one JSON object from selected KV pairs across stages.
build_preflight_json() {
  python3 - "$KV_DIR" "$DEPLOY_MODE" <<'PY'
import sys, json, glob, os
kv_dir = sys.argv[1]
deploy_mode = sys.argv[2]
WANTED = {
    "AZD_VERSION", "AZ_AGENTS_EXT_VERSION", "AZ_CLI_VERSION",
    "ACCOUNT_LOGGED_IN", "ACCOUNT_ACTIVE_SUBSCRIPTION",
    "DEPLOY_MODE", "DEPLOY_MODE_CODE_SUPPORTED",
    "MODEL_DEPLOYMENT", "LOCATION", "MANIFEST_LOCATION", "AZURE_LOCATION",
    "LOCATION_MATCH", "AZURE_YAML_VALID",
    "AZURE_YAML_SERVICE", "AZURE_YAML_HOST",
    "EXPECTED_LANGUAGE", "ACTUAL_LANGUAGE", "DOCKERFILE_PRESENT",
    "SAFE_AZD_INIT",
}
collected = {}
for kv in sorted(glob.glob(os.path.join(kv_dir, "*.kv"))):
    with open(kv) as fh:
        for line in fh:
            if "=" not in line: continue
            k, _, v = line.strip().partition("=")
            if k in WANTED and v:
                collected[k.lower()] = v
collected["status"] = "ok"
collected["deploy_mode"] = deploy_mode
print(json.dumps(collected))
PY
}

PREFLIGHT_JSON="$(build_preflight_json)"

# Ensure status file exists (init is idempotent)
AGENT_NAME="$(basename "$AGENT_PATH")"
"$STATUS_PY" init --agent-path "$AGENT_PATH" --agent-name "$AGENT_NAME" >/dev/null 2>&1 || true

if "$STATUS_PY" update --agent-path "$AGENT_PATH" --section preflight --json "$PREFLIGHT_JSON" >/dev/null; then
  echo "STAGE_stamp_status=ok"
else
  echo "STAGE_stamp_status=warn"
  echo "[!] Could not stamp preflight to agent-status.json (non-fatal)" >&2
fi

# Persist captured KV for /prepare-deploy Step 6 summary
cat "$KV_DIR"/*.kv > "$AGENT_PATH/.preflight.kv" 2>/dev/null || true

echo "PREPARE_DEPLOY=ok"
echo "DEPLOY_MODE=$DEPLOY_MODE"
echo "[✓] /prepare-deploy pipeline complete. \`azd up\` is safe to run." >&2
exit 0
