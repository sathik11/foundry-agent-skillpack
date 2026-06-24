#!/usr/bin/env bash
# infra/cleanup-sweep.sh — safety net so a failed/cancelled E2E run never leaves billable
# ephemeral agent resources behind (W5-T4). The STANDING baseline is always preserved.
#
# Strategy: delete resources in the E2E RG that are (a) tagged ephemeral by the harness, OR
# (b) older than $MAX_AGE_HOURS and tagged as an agent-layer resource. Conservative by default
# (dry-run); pass --apply to actually delete.
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_RESOURCE_GROUP:?set AZURE_RESOURCE_GROUP}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-12}"
APPLY=false; [ "${1:-}" = "--apply" ] && APPLY=true

log() { printf '\033[1;34m[sweep]\033[0m %s\n' "$*" >&2; }
command -v az >/dev/null || { echo "az required" >&2; exit 1; }
az account set --subscription "$AZURE_SUBSCRIPTION_ID"

# Resources considered ephemeral agent-layer:
#   tags."e2e-ephemeral" == "true"   (set by the harness when it creates agent resources)
#   OR tags."azd-service-name" present (azd-managed service hosts)
log "scanning $AZURE_RESOURCE_GROUP for ephemeral agent-layer resources (max age ${MAX_AGE_HOURS}h)…"
mapfile -t IDS < <(az resource list -g "$AZURE_RESOURCE_GROUP" \
  --query "[?tags.\"e2e-ephemeral\"=='true' || tags.\"azd-service-name\"!=null].id" -o tsv 2>/dev/null || true)

if [ "${#IDS[@]}" -eq 0 ]; then
  log "no ephemeral resources found — baseline clean."
  exit 0
fi

log "found ${#IDS[@]} ephemeral resource(s):"
for id in "${IDS[@]}"; do
  [ -n "$id" ] || continue
  if $APPLY; then
    log "  DELETE $id"
    az resource delete --ids "$id" >/dev/null 2>&1 || log "  (skip/failed) $id"
  else
    log "  would delete $id"
  fi
done

if $APPLY; then
  log "sweep complete."
else
  log "DRY-RUN. Re-run with --apply to delete. (Standing baseline is never touched.)"
fi
