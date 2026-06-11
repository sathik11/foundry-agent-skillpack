#!/usr/bin/env bash
# Validate that AZURE_LOCATION in the azd env matches target.location in the
# manifest BEFORE running `azd up`. FB-20 fix: catches the cross-region BYO
# trap where `azd ai agent init` had stamped the RG location into the env,
# overriding the manual `azd env set AZURE_LOCATION <project_region>`.
#
# Recovery emitted on stdout — same command sync-azd-env.sh would have run.
#
# Usage:
#   ./validate-azd-env-location.sh <agent_path>
#
# Exit codes:
#   0 — match; LOCATION_MATCH=true emitted
#   2 — mismatch; LOCATION_MATCH=false + RECOVERY=... emitted (caller STOPS)
#   3 — azd env not set up
#   4 — manifest missing target.location
set -euo pipefail

AGENT_PATH="${1:?usage: $0 <agent_path>}"
MANIFEST="$AGENT_PATH/agent-capabilities.yaml"

if [[ ! -f "$MANIFEST" ]]; then
  echo "[x] Missing manifest: $MANIFEST" >&2
  exit 4
fi

if ! azd env get-name >/dev/null 2>&1; then
  echo "[x] No azd env selected." >&2
  exit 3
fi

# Read AZURE_LOCATION from azd env
ENV_LOC="$(azd env get-value AZURE_LOCATION 2>/dev/null || echo "")"

# Read target.location from manifest
if command -v yq >/dev/null 2>&1; then
  MANIFEST_LOC="$(yq -r '.target.location // ""' "$MANIFEST" 2>/dev/null || echo "")"
else
  MANIFEST_LOC="$(python3 -c "
import yaml
with open('$MANIFEST') as f: d = yaml.safe_load(f) or {}
print((d.get('target') or {}).get('location') or '')
" 2>/dev/null)"
fi

if [[ -z "$MANIFEST_LOC" ]]; then
  echo "[x] manifest.target.location is empty — cannot validate" >&2
  exit 4
fi

echo "MANIFEST_LOCATION=$MANIFEST_LOC"
echo "AZURE_LOCATION=$ENV_LOC"

if [[ "$ENV_LOC" == "$MANIFEST_LOC" ]]; then
  echo "LOCATION_MATCH=true"
  echo "[✓] Location match: $ENV_LOC" >&2
  exit 0
fi

# Mismatch — emit RECOVERY and exit 2 so caller STOPS before azd up
RECOVERY="azd env set AZURE_LOCATION $MANIFEST_LOC"
USE_EXISTING="$(azd env get-value USE_EXISTING_AI_PROJECT 2>/dev/null || echo "")"
if [[ "$USE_EXISTING" != "true" ]]; then
  RECOVERY="$RECOVERY && azd env set USE_EXISTING_AI_PROJECT true"
fi

echo "LOCATION_MATCH=false"
echo "RECOVERY=$RECOVERY"
{
  echo "[x] AZURE_LOCATION mismatch:"
  echo "    azd env AZURE_LOCATION = ${ENV_LOC:-<unset>}"
  echo "    manifest target.location = $MANIFEST_LOC"
  echo "    Recovery: $RECOVERY"
  echo
  echo "[i] Cross-region BYO is supported at RUNTIME (TD-34) but the azd"
  echo "    extension's location inference does not handle it. AZURE_LOCATION"
  echo "    must be the EXISTING project's region, not the resource group's."
} >&2
exit 2
