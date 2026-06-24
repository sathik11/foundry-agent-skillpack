#!/usr/bin/env bash
# infra/baseline.sh — provision / ensure / inspect / tear down the STANDING E2E baseline.
#
# MAINTAINER / CI-ONLY (lives at repo root under infra/, never ships via apm install).
#
# Hybrid infra strategy (plan W5): the slow/expensive layer stands permanently in a dedicated
# RG (Foundry project, capability host, AI Search, Cosmos, Storage, monitoring, APIM AI gateway
# ~45 min cold). Each E2E run recreates only the cheap agent layer (azd up/down) — NOT this.
#
# Subcommands:
#   provision        Deploy/refresh the full standing baseline (idempotent; ARM incremental).
#   ensure           Fast path: if RG + Foundry account exist, no-op; else run provision.
#   outputs [--json] Emit deployment outputs (endpoints, connection names) for the harness.
#   teardown-agents  Delete ONLY ephemeral agent-layer resources (tag azd-service-name / e2e-agent);
#                    the standing baseline is preserved. Used by the cleanup sweep (W5-T4).
#   destroy-all      Delete the entire RG (guarded; requires --yes). Manual use only.
#
# Config: infra/baseline.env (sourced if present) sets the toggles + names. Required env:
#   AZURE_SUBSCRIPTION_ID  AZURE_LOCATION  AZURE_ENV_NAME  AZURE_RESOURCE_GROUP
# Optional: AZURE_PRINCIPAL_ID (objectId to grant data-plane roles; auto-resolved if omitted).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP="$HERE/main.bicep"
[ -f "$HERE/baseline.env" ] && source "$HERE/baseline.env"

: "${AZURE_SUBSCRIPTION_ID:?set AZURE_SUBSCRIPTION_ID}"
: "${AZURE_LOCATION:?set AZURE_LOCATION (e.g. eastus2)}"
: "${AZURE_ENV_NAME:?set AZURE_ENV_NAME (e.g. skillpack-e2e)}"
: "${AZURE_RESOURCE_GROUP:?set AZURE_RESOURCE_GROUP (dedicated RG)}"

# Standing-baseline toggles (overridable via baseline.env / env).
ENABLE_MONITORING="${ENABLE_MONITORING:-true}"
ENABLE_HOSTED_AGENTS="${ENABLE_HOSTED_AGENTS:-true}"
ENABLE_COSMOS="${ENABLE_COSMOS:-true}"
ENABLE_STORAGE="${ENABLE_STORAGE:-true}"
ENABLE_SEARCH="${ENABLE_SEARCH:-true}"
ENABLE_APIM="${ENABLE_APIM:-true}"
APIM_SKU_NAME="${APIM_SKU_NAME:-Developer}"
APIM_PUBLISHER_EMAIL="${APIM_PUBLISHER_EMAIL:-admin@example.com}"
APIM_PUBLISHER_NAME="${APIM_PUBLISHER_NAME:-Skillpack E2E}"
# Model deployment(s) for the agent-under-test (NOT the driver brain, which lives in a
# separate RG). JSON array per the bicep schema. Override in baseline.env.
AI_PROJECT_DEPLOYMENTS="${AI_PROJECT_DEPLOYMENTS:-[]}"
DEPLOYMENT_NAME="${DEPLOYMENT_NAME:-skillpack-e2e-baseline}"

log() { printf '\033[1;34m[baseline]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[baseline] %s\033[0m\n' "$*" >&2; exit 1; }

require_az() {
  command -v az >/dev/null || die "az CLI not found"
  az account show >/dev/null 2>&1 || die "not logged in (az login / OIDC)"
  az account set --subscription "$AZURE_SUBSCRIPTION_ID"
}

resolve_principal() {
  if [ -n "${AZURE_PRINCIPAL_ID:-}" ]; then echo "$AZURE_PRINCIPAL_ID"; return; fi
  # SP (CI) vs user (local). Try signed-in user first, then the SP behind the current login.
  local oid
  oid="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  if [ -z "$oid" ]; then
    local appid; appid="$(az account show --query user.name -o tsv 2>/dev/null || true)"
    oid="$(az ad sp show --id "$appid" --query id -o tsv 2>/dev/null || true)"
  fi
  [ -n "$oid" ] || die "could not resolve principal objectId; set AZURE_PRINCIPAL_ID"
  echo "$oid"
}

principal_type() {
  # ServicePrincipal in CI, User locally.
  if az ad signed-in-user show >/dev/null 2>&1; then echo User; else echo ServicePrincipal; fi
}

do_provision() {
  require_az
  local pid ptype; pid="$(resolve_principal)"; ptype="$(principal_type)"
  log "provisioning standing baseline → RG=$AZURE_RESOURCE_GROUP loc=$AZURE_LOCATION apim=$ENABLE_APIM($APIM_SKU_NAME)"
  log "NOTE: APIM Developer SKU cold-provision is ~45 min — expected, not a hang."
  az deployment sub create \
    --name "$DEPLOYMENT_NAME" \
    --location "$AZURE_LOCATION" \
    --template-file "$BICEP" \
    --parameters \
      environmentName="$AZURE_ENV_NAME" \
      resourceGroupName="$AZURE_RESOURCE_GROUP" \
      location="$AZURE_LOCATION" \
      principalId="$pid" \
      principalType="$ptype" \
      enableMonitoring="$ENABLE_MONITORING" \
      enableHostedAgents="$ENABLE_HOSTED_AGENTS" \
      enableCapabilityHost=true \
      enableCosmos="$ENABLE_COSMOS" \
      enableStorage="$ENABLE_STORAGE" \
      enableSearch="$ENABLE_SEARCH" \
      enableApim="$ENABLE_APIM" \
      apimSkuName="$APIM_SKU_NAME" \
      apimPublisherEmail="$APIM_PUBLISHER_EMAIL" \
      apimPublisherName="$APIM_PUBLISHER_NAME" \
      aiProjectDeploymentsJson="$AI_PROJECT_DEPLOYMENTS" \
    --output none
  log "provision complete."
  do_outputs
}

do_ensure() {
  require_az
  if az group show -n "$AZURE_RESOURCE_GROUP" >/dev/null 2>&1 \
     && az resource list -g "$AZURE_RESOURCE_GROUP" \
          --resource-type Microsoft.CognitiveServices/accounts \
          --query "[0].id" -o tsv 2>/dev/null | grep -q .; then
    log "baseline already present in $AZURE_RESOURCE_GROUP — skipping provision (use 'provision' to refresh)."
    return 0
  fi
  log "baseline missing — running provision."
  do_provision
}

do_outputs() {
  require_az
  local json; json="$(az deployment sub show -n "$DEPLOYMENT_NAME" \
    --query "properties.outputs" -o json 2>/dev/null || echo '{}')"
  if [ "${1:-}" = "--json" ]; then echo "$json"; return; fi
  # KEY=VALUE for sourcing into the harness env.
  echo "$json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
for k,v in d.items():
    print(f"{k.upper()}={v.get(\"value\",\"\")}")'
}

do_teardown_agents() {
  require_az
  log "deleting ONLY ephemeral agent-layer resources (baseline preserved)…"
  # Agent-layer resources are tagged when created by the harness (azd-service-name) or our e2e tag.
  local ids
  ids="$(az resource list -g "$AZURE_RESOURCE_GROUP" \
    --query "[?tags.\"e2e-ephemeral\"=='true' || tags.\"azd-service-name\"!=null].id" -o tsv 2>/dev/null || true)"
  if [ -z "$ids" ]; then log "no ephemeral agent resources found."; return 0; fi
  echo "$ids" | while read -r id; do [ -n "$id" ] && { log "  delete $id"; az resource delete --ids "$id" --verbose >/dev/null 2>&1 || log "  (skip) $id"; }; done
  log "agent-layer teardown complete."
}

do_destroy_all() {
  [ "${1:-}" = "--yes" ] || die "destroy-all removes the WHOLE RG. Re-run with --yes to confirm."
  require_az
  log "deleting resource group $AZURE_RESOURCE_GROUP (no-wait)…"
  az group delete -n "$AZURE_RESOURCE_GROUP" --yes --no-wait
  log "deletion dispatched."
}

cmd="${1:-}"; shift || true
case "$cmd" in
  provision)        do_provision "$@" ;;
  ensure)           do_ensure "$@" ;;
  outputs)          do_outputs "$@" ;;
  teardown-agents)  do_teardown_agents "$@" ;;
  destroy-all)      do_destroy_all "$@" ;;
  *) die "usage: baseline.sh {provision|ensure|outputs [--json]|teardown-agents|destroy-all --yes}" ;;
esac
