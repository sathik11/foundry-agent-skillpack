#!/usr/bin/env bash
# Read the cached project topology (./assessment/project-topology.json)
# and emit KEY=VALUE on stdout. Single approval; the prompt greps what it
# needs instead of three separate inline-python heredocs (FB-12).
#
# Why this exists: `/prepare-deploy` was opening project-topology.json in
# three separate Python heredocs (one per field family). Each heredoc was
# a separate `run_in_terminal` approval; each was a place to fail silently.
# This collapses them to a single KV stream the prompt can parse with grep.
#
# Usage:
#   ./read-topology.sh                                 # emit all well-known fields
#   ./read-topology.sh --json <jq-path>                # one specific path
#   ./read-topology.sh --topology-file <path>          # override default location
#
# Default topology file: ./assessment/project-topology.json
#
# Exit codes:
#   0 — topology read; KEY=VALUE on stdout
#   2 — topology file not found (run /assess-project first)
#   3 — topology file present but malformed
#   4 — specific --json field requested but not present
set -euo pipefail

TOPOLOGY_FILE="./assessment/project-topology.json"
JSON_PATH=""

while (( $# > 0 )); do
  case "$1" in
    --json)
      JSON_PATH="${2:?--json requires a jq path argument}"
      shift 2
      ;;
    --topology-file)
      TOPOLOGY_FILE="${2:?--topology-file requires a path}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "[x] Unknown flag: $1" >&2
      exit 64  # EX_USAGE
      ;;
  esac
done

if [[ ! -f "$TOPOLOGY_FILE" ]]; then
  echo "[x] Topology file not found: $TOPOLOGY_FILE" >&2
  echo "[i] Run /assess-project first to create it." >&2
  echo "TOPOLOGY_FOUND=false"
  exit 2
fi

if ! jq empty "$TOPOLOGY_FILE" 2>/dev/null; then
  echo "[x] Topology file malformed: $TOPOLOGY_FILE" >&2
  echo "TOPOLOGY_FOUND=true"
  echo "TOPOLOGY_VALID=false"
  exit 3
fi

# Single-field mode
if [[ -n "$JSON_PATH" ]]; then
  VALUE="$(jq -r "$JSON_PATH // empty" "$TOPOLOGY_FILE")"
  if [[ -z "$VALUE" ]]; then
    echo "[x] Field not present in topology: $JSON_PATH" >&2
    exit 4
  fi
  # Emit as KEY=VALUE where KEY is the last jq path segment, upper-cased
  KEY="$(echo "$JSON_PATH" | sed 's/.*\.//' | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9_' '_' | sed 's/_*$//')"
  echo "${KEY}=${VALUE}"
  exit 0
fi

# Full dump — well-known fields used by /plan-agent and /prepare-deploy.
# Silent (no [i]) — this is a hot path called per-step.
echo "TOPOLOGY_FOUND=true"
echo "TOPOLOGY_VALID=true"
echo "TOPOLOGY_FILE=$TOPOLOGY_FILE"

emit() {
  # emit <KEY> <jq-path>  — only echo if value is non-null/non-empty.
  # NOTE: must always return 0 — the script runs under `set -e`, and a bare
  # `[[ -n "$value" ]] && echo` returns 1 when the field is absent, which would
  # abort the whole dump on the first missing optional field.
  local key="$1" path="$2"
  local value
  value="$(jq -r "$path // empty" "$TOPOLOGY_FILE" 2>/dev/null || echo "")"
  [[ -n "$value" ]] && echo "${key}=${value}"
  return 0
}

emit SUBSCRIPTION_ID    '.subscription_id'
emit RESOURCE_GROUP     '.resource_group'
emit ACCOUNT_NAME       '.account.name'
emit ACCOUNT_LOCATION   '.account.location'
emit PROJECT_NAME       '.project.name'
emit PROJECT_LOCATION   '.project.location'
emit ACR_NAME           '.acr.name'
emit ACR_LOGIN_SERVER   '.acr.login_server'
emit DEPLOYMENT_COUNT   '.deployments.count'
emit DEPLOYMENT_NAMES   '.deployments.names | join(",")'
emit CAPHOST_PRESENT    '.capability_host.present'
emit NETWORK_INJECTION  '.network.injection_kind'
emit AGENT_COUNT        '.agents.count'

exit 0
