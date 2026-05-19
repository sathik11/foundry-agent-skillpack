#!/usr/bin/env bash
# Guard wrapper for `azd ai agent init`. Checks for hazards before running.
#
# Hazards:
#   1. Existing .git — azd init can reinitialize it.
#   2. Existing azure.yaml — azd init may overwrite.
#   3. Existing agent files (agent.yaml, main.py, Dockerfile) — would be clobbered.
#
# Usage:
#   ./safe-azd-init.sh <agent_path> [azd ai agent init flags...]
#
# Example:
#   ./safe-azd-init.sh agents/my-agent \
#     --manifest agents/my-agent/agent.yaml \
#     --src agents/my-agent \
#     --model-deployment gpt-5.4-1 \
#     --protocol responses
#
# Exit codes:
#   0 — azd init ran successfully (or was skipped because azure.yaml already exists).
#   1 — hazard detected; user must confirm or resolve.
#   2 — azd init failed for another reason.
set -euo pipefail

AGENT_PATH="${1:?usage: $0 <agent_path> [azd-init-flags...]}"
shift

# Resolve workspace root (walk up from agent_path to find apm.yml or .git)
WORKSPACE_ROOT="$(pwd)"

HAZARDS=()

# --- Check 1: .git exists ---
if [[ -d "$WORKSPACE_ROOT/.git" ]]; then
  echo "[i] .git exists at workspace root — azd init may try to reinitialize." >&2
  # This is informational, not blocking. azd usually handles this OK.
fi

# --- Check 2: azure.yaml already exists ---
if [[ -f "$WORKSPACE_ROOT/azure.yaml" ]]; then
  echo "[✓] azure.yaml already exists. Skipping azd ai agent init (idempotent)." >&2
  echo "SAFE_AZD_INIT=skipped"
  echo "AZURE_YAML=exists"
  exit 0
fi

# --- Check 3: agent files that would be overwritten ---
CLOBBER_FILES=()
for f in agent.yaml main.py Dockerfile requirements.txt; do
  if [[ -f "$AGENT_PATH/$f" ]]; then
    CLOBBER_FILES+=("$AGENT_PATH/$f")
  fi
done

if (( ${#CLOBBER_FILES[@]} > 0 )); then
  echo "[!] azd ai agent init may overwrite these existing files:" >&2
  for f in "${CLOBBER_FILES[@]}"; do
    echo "    - $f" >&2
  done
  echo >&2
  echo "[i] The --src flag tells azd where existing source lives." >&2
  echo "    If your agent code is already complete, you may only need" >&2
  echo "    'azd init' (not 'azd ai agent init') to scaffold azure.yaml." >&2
  echo >&2
  echo "SAFE_AZD_INIT=clobber-risk"
  echo "CLOBBER_FILES=${CLOBBER_FILES[*]}"

  # Still proceed if the caller passed --src pointing to the agent path
  # (azd should respect existing files when --src is explicit)
  HAS_SRC=false
  for arg in "$@"; do
    [[ "$arg" == "--src" ]] && HAS_SRC=true
  done

  if [[ "$HAS_SRC" == "true" ]]; then
    echo "[i] --src flag detected — azd should respect existing source files." >&2
  else
    echo "[x] No --src flag. Add '--src $AGENT_PATH' to protect existing files." >&2
    HAZARDS+=("no-src-flag")
  fi
fi

# --- If hazards remain, emit the command but don't execute ---
if (( ${#HAZARDS[@]} > 0 )); then
  echo >&2
  echo "### Recommended command (review before running):" >&2
  echo "  azd ai agent init --src $AGENT_PATH $*" >&2
  echo >&2
  echo "SAFE_AZD_INIT=blocked"
  exit 1
fi

# --- Safe to run ---
echo "[+] Running: azd ai agent init $*" >&2
if azd ai agent init "$@" 2>&1; then
  echo "SAFE_AZD_INIT=success"
  echo "AZURE_YAML=created"
  echo "[✓] azd ai agent init completed." >&2
  exit 0
else
  echo "SAFE_AZD_INIT=failed"
  echo "[x] azd ai agent init failed." >&2
  exit 2
fi
