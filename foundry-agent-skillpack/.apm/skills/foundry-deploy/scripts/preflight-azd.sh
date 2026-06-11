#!/usr/bin/env bash
# Single-approval preflight for all azd/az tooling versions. Replaces the
# H6/H7/H8/H9/H10 raw-bash ceremony in /prepare-deploy (FB-8, FB-9, FB-10, FB-17).
#
# Floors come from foundry-deploy/versions.yaml (FB-8). When the file is
# missing or unreadable, fall back to baked-in defaults so the script still
# works on older skillpack installs.
#
# Usage:
#   ./preflight-azd.sh [--deploy-mode <container|code>]
#
# Exit codes:
#   0 — all gates ok; KV summary on stdout
#   2 — one or more gates failed; FAIL_REASON=... + RECOVERY=... emitted (caller STOPS)
set -euo pipefail

DEPLOY_MODE="container"
while (( $# > 0 )); do
  case "$1" in
    --deploy-mode) DEPLOY_MODE="${2:?--deploy-mode requires container|code}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "[x] Unknown flag: $1" >&2; exit 64 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/../versions.yaml"

# Defaults (kept in sync with versions.yaml; updated in lockstep at release).
DEFAULT_AZD_FLOOR="1.10.0"
DEFAULT_AGENTS_EXT_FLOOR="0.1.27-preview"
DEFAULT_AZ_FLOOR="2.65.0"

read_floor() {
  local key="$1" default="$2"
  if [[ -f "$VERSIONS_FILE" ]] && command -v yq >/dev/null 2>&1; then
    yq -r ".$key // \"$default\"" "$VERSIONS_FILE" 2>/dev/null || echo "$default"
  else
    echo "$default"
  fi
}

AZD_FLOOR="$(read_floor azd "$DEFAULT_AZD_FLOOR")"
AGENTS_EXT_FLOOR="$(read_floor az_agents_ext "$DEFAULT_AGENTS_EXT_FLOOR")"
AZ_FLOOR="$(read_floor az "$DEFAULT_AZ_FLOOR")"

# semver-ish compare: returns 0 if $1 >= $2 (works for X.Y.Z and X.Y.Z-suffix).
ver_ge() {
  local a="$1" b="$2"
  printf '%s\n%s\n' "$b" "$a" | sort -V | head -1 | grep -qx "$b"
}

FAIL=0
FAIL_REASON=""
RECOVERY=""

# H6: azd CLI present and >= floor
if ! command -v azd >/dev/null 2>&1; then
  FAIL=1; FAIL_REASON="azd_not_installed"
  RECOVERY="Install azd: curl -fsSL https://aka.ms/install-azd.sh | bash"
else
  AZD_VERSION="$(azd version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")"
  echo "AZD_VERSION=$AZD_VERSION"
  if [[ -n "$AZD_VERSION" ]] && ! ver_ge "$AZD_VERSION" "$AZD_FLOOR"; then
    FAIL=1; FAIL_REASON="azd_below_floor"
    RECOVERY="azd upgrade   (have: $AZD_VERSION, need: >= $AZD_FLOOR)"
  fi
fi
echo "AZD_REQUIRED=$AZD_FLOOR"

# H7: azure.ai.agents extension installed + >= floor
if [[ $FAIL -eq 0 ]] && command -v azd >/dev/null 2>&1; then
  EXT_VERSION="$(azd extension list 2>/dev/null | awk '/azure\.ai\.agents/ {print $2}' | head -1 || echo "")"
  echo "AZ_AGENTS_EXT_VERSION=$EXT_VERSION"
  if [[ -z "$EXT_VERSION" ]]; then
    FAIL=1; FAIL_REASON="agents_ext_not_installed"
    RECOVERY="azd extension install azure.ai.agents"
  elif ! ver_ge "$EXT_VERSION" "$AGENTS_EXT_FLOOR"; then
    FAIL=1; FAIL_REASON="agents_ext_below_floor"
    RECOVERY="azd extension upgrade azure.ai.agents   (have: $EXT_VERSION, need: >= $AGENTS_EXT_FLOOR)"
  fi
fi
echo "AZ_AGENTS_EXT_REQUIRED=$AGENTS_EXT_FLOOR"

# H8: az CLI present and >= floor
if [[ $FAIL -eq 0 ]]; then
  if ! command -v az >/dev/null 2>&1; then
    FAIL=1; FAIL_REASON="az_not_installed"
    RECOVERY="Install Azure CLI: https://aka.ms/installazurecli"
  else
    AZ_VERSION="$(az version --query '\"azure-cli\"' -o tsv 2>/dev/null || echo "")"
    echo "AZ_CLI_VERSION=$AZ_VERSION"
    if [[ -n "$AZ_VERSION" ]] && ! ver_ge "$AZ_VERSION" "$AZ_FLOOR"; then
      FAIL=1; FAIL_REASON="az_below_floor"
      RECOVERY="az upgrade   (have: $AZ_VERSION, need: >= $AZ_FLOOR)"
    fi
  fi
fi
echo "AZ_CLI_REQUIRED=$AZ_FLOOR"

# H9: caller logged in to az
if [[ $FAIL -eq 0 ]]; then
  if ! az account show >/dev/null 2>&1; then
    FAIL=1; FAIL_REASON="az_not_logged_in"
    RECOVERY="az login --tenant <tenant>"
    echo "ACCOUNT_LOGGED_IN=false"
  else
    SUB_ID="$(az account show --query id -o tsv 2>/dev/null || echo "")"
    echo "ACCOUNT_LOGGED_IN=true"
    echo "ACCOUNT_ACTIVE_SUBSCRIPTION=$SUB_ID"
  fi
fi

# H10: deploy-mode code support (only when deploy_mode: code)
if [[ $FAIL -eq 0 && "$DEPLOY_MODE" == "code" ]]; then
  if azd ai agent init --deploy-mode code --help >/dev/null 2>&1; then
    echo "DEPLOY_MODE_CODE_SUPPORTED=true"
  else
    FAIL=1; FAIL_REASON="deploy_mode_code_not_supported"
    RECOVERY="azd extension upgrade azure.ai.agents   (current version predates --deploy-mode code)"
    echo "DEPLOY_MODE_CODE_SUPPORTED=false"
  fi
fi

if [[ $FAIL -eq 0 ]]; then
  echo "PREFLIGHT_AZD=ok"
  exit 0
fi

echo "PREFLIGHT_AZD=failed"
echo "FAIL_REASON=$FAIL_REASON"
echo "RECOVERY=$RECOVERY"
{
  echo "[x] azd preflight failed: $FAIL_REASON"
  echo "    Recovery: $RECOVERY"
} >&2
exit 2
