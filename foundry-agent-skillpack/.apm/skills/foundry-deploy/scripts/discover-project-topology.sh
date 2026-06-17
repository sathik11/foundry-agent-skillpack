#!/usr/bin/env bash
# Discover the FULL Foundry project topology — every resource category that
# could matter to an agent's deploy / runtime / governance posture.
#
# This is a SUPERSET of discover-target.sh:
#   discover-target.sh         → minimum needed to deploy a container/code agent
#                                (account + project + ACR + 1 model deployment)
#   discover-project-topology  → everything: connections, capabilityHosts,
#                                network injection, deployments inventory,
#                                hosted agents, quota usage, identity surface
#
# Used by /assess-project for read-only topology assessment. Also consumed by
# /plan-agent (Step 0a cached topology pickup), /prepare-deploy (Step 2 cross-
# check), and /troubleshoot (Scenario 4 — symptom matches topology gap).
#
# Outputs KEY=VALUE pairs to stdout (machine-readable, grouped by prefix).
# Human context goes to stderr. Read-only — no mutations.
#
# Usage:
#   ./discover-project-topology.sh <subscription_id> <resource_group> \
#       [<account_name>] [<project_name>]
#
# Output key prefixes:
#   ACCOUNT_*       — Foundry account (CognitiveServices/accounts) facts
#   PROJECT_*       — selected project facts
#   CONNECTION_*    — project connections (AI Search, Cosmos, Storage, Fabric…)
#   CAPHOST_*       — capability hosts at BOTH scopes (account + project).
#                     CAPHOST_ACCOUNT_COUNT / CAPHOST_PROJECT_COUNT are the
#                     two top-level signals; per-host detail under
#                     CAPHOST_ACCOUNT_<n>_* and CAPHOST_PROJECT_<n>_*.
#                     Legacy CAPHOST_COUNT alias = CAPHOST_PROJECT_COUNT.
#   NETWORK_*       — networkInjections, public network access, NSP
#   DEPLOYMENT_*    — model deployments inventory (cross-account)
#   AGENT_*         — hosted agents listed via control plane
#   IDENTITY_*      — account/project system-assigned & user-assigned MIs
#   QUOTA_*         — usage / quota signals (best-effort, tolerated empty)
#   TOPOLOGY_*      — summary keys: STATUS, FOUNDRY_GRADE, RESOURCE_COUNT, ...
#
# Exit codes:
#   0 — Foundry-grade account found; topology emitted (may include ⚠ verdicts)
#   2 — Account found but `allowProjectManagement != true` (not Foundry-grade)
#   3 — No CognitiveServices/AIServices account in the resource group
#   4 — Ambiguous: multiple Foundry-grade accounts or projects in the RG and no
#       hint supplied. Caller must re-invoke with positional `<account_name>`
#       (and `<project_name>` if needed). Candidate list is emitted as
#       ACCOUNT_NAME_<n>= / PROJECT_NAME_<n>= keys on stdout BEFORE exit.
#
# Notes on api-version pins (invariant #9 — never wrap az rest in `|| echo '[]'`
# without stderr capture; pin to current GA / current preview floor):
#   - accounts/projects                 = 2026-03-01 (GA — matches discover-target)
#   - accounts/projects/connections     = 2026-03-01 (GA)
#   - accounts/projects/capabilityHosts = 2026-03-01 (GA)
#   - accounts/networkInjections        = 2026-03-01 (GA — per managed-VNet docs)
#   - accounts/deployments              = 2024-10-01 (GA — via az cli)
#   - accounts/projects/agents          = v1 (control plane; audience
#     https://ai.azure.com — see F-28)
#
# When a preview surface bumps, surface the rc + stderr instead of swallowing.
set -euo pipefail

SUB="${1:?usage: $0 <subscription_id> <resource_group> [<account_name>] [<project_name>]}"
RG="${2:?usage: $0 <subscription_id> <resource_group> [<account_name>] [<project_name>]}"
HINT_ACCOUNT="${3:-}"
HINT_PROJECT="${4:-}"

PROJECTS_API_VERSION="2026-03-01"
CONNECTIONS_API_VERSION="2026-03-01"
CAPHOSTS_API_VERSION="2026-03-01"
NETWORK_API_VERSION="2026-03-01"
AGENTS_API_VERSION="v1"

echo "SUBSCRIPTION_ID=$SUB"
echo "RESOURCE_GROUP=$RG"
echo "[i] Foundry project topology discovery (read-only) starting…" >&2

# ----------------------------------------------------------------------------
# 1. Account discovery + Foundry-grade check (allowProjectManagement)
# ----------------------------------------------------------------------------
echo "[i] Listing CognitiveServices accounts in $RG…" >&2
ACCOUNTS_JSON=$(az cognitiveservices account list -g "$RG" --subscription "$SUB" -o json 2>/dev/null || echo "[]")
ACCOUNT_COUNT=$(echo "$ACCOUNTS_JSON" | jq 'length')

if (( ACCOUNT_COUNT == 0 )); then
  echo "[x] No CognitiveServices/AIServices account in $RG." >&2
  echo "TOPOLOGY_STATUS=no-account"
  echo "TOPOLOGY_FOUNDRY_GRADE=false"
  echo "ACCOUNT_COUNT=0"
  exit 3
fi

# Select the account: explicit hint > exactly-one Foundry-grade > ambiguous-exit-4.
# Foundry-grade = allowProjectManagement=true AND kind matches AIServices.
# We NEVER silently pick idx 0 when multiple Foundry-grade candidates exist —
# the caller must disambiguate (the prompt's Step 1 surfaces a picklist).
FOUNDRY_INDICES=$(echo "$ACCOUNTS_JSON" \
  | jq -r '[ .[] | select(.kind == "AIServices" and .properties.allowProjectManagement == true) ] as $f
           | [ range(0; ($f | length)) as $i | ($f[$i].name) ] | .[]')
FOUNDRY_GRADE_COUNT=$(printf '%s\n' "$FOUNDRY_INDICES" | grep -c . || true)
echo "ACCOUNT_FOUNDRY_GRADE_COUNT=$FOUNDRY_GRADE_COUNT"

# Always emit the full account candidate list up front (works for picklists on exit 4).
if (( ACCOUNT_COUNT > 0 )); then
  echo "[i] Accounts in RG '$RG' (count=$ACCOUNT_COUNT, foundry-grade=$FOUNDRY_GRADE_COUNT):" >&2
  for i in $(seq 0 $((ACCOUNT_COUNT - 1))); do
    N=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].name")
    K=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].kind")
    APM=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].properties.allowProjectManagement // false")
    LOC=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].location // \"\"")
    echo "  $((i+1)). $N (kind=$K, foundry-grade=$APM, location=$LOC)" >&2
    echo "ACCOUNT_NAME_$((i+1))=$N"
    echo "ACCOUNT_KIND_$((i+1))=$K"
    echo "ACCOUNT_ALLOW_PROJECT_MANAGEMENT_$((i+1))=$APM"
    echo "ACCOUNT_LOCATION_$((i+1))=$LOC"
  done
fi

SELECTED_IDX=""
if [[ -n "$HINT_ACCOUNT" ]]; then
  IDX=$(echo "$ACCOUNTS_JSON" | jq -r --arg n "$HINT_ACCOUNT" '[.[].name] | index($n)')
  if [[ "$IDX" == "null" || -z "$IDX" ]]; then
    echo "[x] Account hint '$HINT_ACCOUNT' not found in '$RG'. Pick from the list above and re-run." >&2
    echo "TOPOLOGY_STATUS=ambiguous-account"
    echo "TOPOLOGY_FOUNDRY_GRADE=$([ "$FOUNDRY_GRADE_COUNT" -gt 0 ] && echo true || echo false)"
    exit 4
  fi
  SELECTED_IDX="$IDX"
elif (( FOUNDRY_GRADE_COUNT == 1 )); then
  ONLY=$(printf '%s\n' "$FOUNDRY_INDICES" | head -n 1)
  SELECTED_IDX=$(echo "$ACCOUNTS_JSON" | jq -r --arg n "$ONLY" '[.[].name] | index($n)')
  echo "[i] Auto-selected the only Foundry-grade account: $ONLY" >&2
elif (( FOUNDRY_GRADE_COUNT > 1 )); then
  echo "[x] Ambiguous: $FOUNDRY_GRADE_COUNT Foundry-grade accounts in '$RG'. Re-run with positional argument:" >&2
  echo "      $0 $SUB $RG <account_name> [<project_name>]" >&2
  echo "    Candidates (also emitted as ACCOUNT_NAME_<n> keys on stdout):" >&2
  printf '%s\n' "$FOUNDRY_INDICES" | sed 's/^/      - /' >&2
  echo "TOPOLOGY_STATUS=ambiguous-account"
  echo "TOPOLOGY_FOUNDRY_GRADE=true"
  exit 4
else
  # Zero Foundry-grade — fall through to the existing "not foundry-grade" path
  # by picking idx 0 so the gate below produces the right exit-2 message.
  SELECTED_IDX=0
fi

ACCT_NAME=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].name")
ACCT_ID=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].id")
ACCT_KIND=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].kind")
ACCT_LOC=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].location")
ACCT_SKU=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].sku.name // \"unknown\"")
ALLOW_PROJ_MGMT=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].properties.allowProjectManagement // false")
PUB_NET_ACCESS=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].properties.publicNetworkAccess // \"unknown\"")
PE_COUNT=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].properties.privateEndpointConnections // [] | length")
DISABLE_LOCAL_AUTH=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].properties.disableLocalAuth // false")
CUSTOM_SUBDOMAIN=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].properties.customSubDomainName // \"\"")

echo "ACCOUNT_NAME=$ACCT_NAME"
echo "ACCOUNT_ID=$ACCT_ID"
echo "ACCOUNT_KIND=$ACCT_KIND"
echo "ACCOUNT_LOCATION=$ACCT_LOC"
echo "ACCOUNT_SKU=$ACCT_SKU"
echo "ACCOUNT_ALLOW_PROJECT_MANAGEMENT=$ALLOW_PROJ_MGMT"
echo "ACCOUNT_PUBLIC_NETWORK_ACCESS=$PUB_NET_ACCESS"
echo "ACCOUNT_PRIVATE_ENDPOINT_COUNT=$PE_COUNT"
echo "ACCOUNT_DISABLE_LOCAL_AUTH=$DISABLE_LOCAL_AUTH"
echo "ACCOUNT_CUSTOM_SUBDOMAIN=$CUSTOM_SUBDOMAIN"
echo "ACCOUNT_COUNT=$ACCOUNT_COUNT"

# Foundry-grade gate
if [[ "$ALLOW_PROJ_MGMT" != "true" ]]; then
  echo "[x] Account '$ACCT_NAME' is NOT Foundry-grade (allowProjectManagement=$ALLOW_PROJ_MGMT)." >&2
  echo "    Hosted-agent workloads require a Foundry account. Recreate the account with" >&2
  echo "    allowProjectManagement=true, or pick a different account." >&2
  echo "TOPOLOGY_STATUS=not-foundry-grade"
  echo "TOPOLOGY_FOUNDRY_GRADE=false"
  exit 2
fi

# Surface identity (system + user-assigned)
SA_PID=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].identity.principalId // \"\"")
SA_TID=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].identity.tenantId // \"\"")
ID_TYPE=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].identity.type // \"None\"")
UAMI_COUNT=$(echo "$ACCOUNTS_JSON" | jq -r ".[$SELECTED_IDX].identity.userAssignedIdentities // {} | length")
echo "IDENTITY_TYPE=$ID_TYPE"
echo "IDENTITY_SYSTEM_ASSIGNED_PRINCIPAL_ID=$SA_PID"
echo "IDENTITY_SYSTEM_ASSIGNED_TENANT_ID=$SA_TID"
echo "IDENTITY_USER_ASSIGNED_COUNT=$UAMI_COUNT"

# List other accounts for visibility (multi-account RG case).
# NOTE: The full ACCOUNT_NAME_<n> / ACCOUNT_KIND_<n> / ACCOUNT_ALLOW_PROJECT_MANAGEMENT_<n>
# keys were emitted eagerly above (before the ambiguity gate) so picklists work
# even on exit 4. This block is now stderr-only context.
if (( ACCOUNT_COUNT > 1 )); then
  echo "[i] Multi-account RG: selected '$ACCT_NAME' (idx $SELECTED_IDX) for project assessment." >&2
fi

# ----------------------------------------------------------------------------
# 2. Projects under the selected account
# ----------------------------------------------------------------------------
echo "[i] Listing projects under $ACCT_NAME (api-version=$PROJECTS_API_VERSION)…" >&2
PROJ_RESP=$(az rest --method GET \
  --url "https://management.azure.com${ACCT_ID}/projects?api-version=${PROJECTS_API_VERSION}" \
  2>&1) || PROJ_RC=$?
PROJ_RC=${PROJ_RC:-0}
if (( PROJ_RC != 0 )); then
  echo "[!] Projects API failed (rc=$PROJ_RC). Bump api-version or check RBAC." >&2
  echo "    Response: $(echo "$PROJ_RESP" | head -c 240)" >&2
  PROJECTS_JSON='{"value":[]}'
else
  PROJECTS_JSON="$PROJ_RESP"
fi
unset PROJ_RC

PROJ_COUNT=$(echo "$PROJECTS_JSON" | jq '.value | length')
echo "PROJECT_COUNT=$PROJ_COUNT"

if (( PROJ_COUNT == 0 )); then
  echo "[x] No projects under account $ACCT_NAME. Agent workloads need at least one project." >&2
  echo "PROJECT_NAME="
  echo "TOPOLOGY_STATUS=no-project"
  echo "TOPOLOGY_FOUNDRY_GRADE=true"
  exit 0
fi

# Always emit the full project candidate list up front (works for picklists on exit 4).
for j in $(seq 0 $((PROJ_COUNT - 1))); do
  N=$(echo "$PROJECTS_JSON" | jq -r ".value[$j].name")
  echo "PROJECT_NAME_$((j+1))=$N"
done

# Select project: explicit hint > exactly-one-project > ambiguous-exit-4.
# We NEVER silently pick idx 0 when multiple projects exist.
# Hint matching accepts EITHER the full "account/project" path that ARM returns
# OR just the project leaf name (last segment). Defect surfaced in v0.26.0 testing
# where API returns `.name = "<account>/<project>"` but users naturally pass just
# the project leaf they see in the portal.
PROJ_IDX=""
if [[ -n "$HINT_PROJECT" ]]; then
  PIDX=$(echo "$PROJECTS_JSON" | jq -r --arg n "$HINT_PROJECT" '
    [.value[].name] as $full
    | [$full[] | split("/") | .[-1]] as $leaf
    | ($full | index($n)) // ($leaf | index($n))
  ')
  if [[ "$PIDX" == "null" || -z "$PIDX" ]]; then
    echo "[x] Project hint '$HINT_PROJECT' not found on account '$ACCT_NAME'. Pick from the list above and re-run." >&2
    echo "TOPOLOGY_STATUS=ambiguous-project"
    echo "TOPOLOGY_FOUNDRY_GRADE=true"
    exit 4
  fi
  PROJ_IDX="$PIDX"
elif (( PROJ_COUNT == 1 )); then
  PROJ_IDX=0
else
  echo "[x] Ambiguous: $PROJ_COUNT projects under account '$ACCT_NAME'. Re-run with positional argument:" >&2
  echo "      $0 $SUB $RG $ACCT_NAME <project_name>" >&2
  echo "    Candidates (also emitted as PROJECT_NAME_<n> keys on stdout):" >&2
  for j in $(seq 0 $((PROJ_COUNT - 1))); do
    N=$(echo "$PROJECTS_JSON" | jq -r ".value[$j].name")
    echo "      - $N" >&2
  done
  echo "TOPOLOGY_STATUS=ambiguous-project"
  echo "TOPOLOGY_FOUNDRY_GRADE=true"
  exit 4
fi

PROJ_NAME=$(echo "$PROJECTS_JSON" | jq -r ".value[$PROJ_IDX].name")
PROJ_ID=$(echo "$PROJECTS_JSON" | jq -r ".value[$PROJ_IDX].id")
PROJ_LOC=$(echo "$PROJECTS_JSON" | jq -r ".value[$PROJ_IDX].location // \"unknown\"")
PROJ_ENDPOINT=$(echo "$PROJECTS_JSON" | jq -r ".value[$PROJ_IDX].properties.endpoints.\"AI Foundry API\" // .value[$PROJ_IDX].properties.endpoint // \"\"")
echo "PROJECT_NAME=$PROJ_NAME"
echo "PROJECT_ID=$PROJ_ID"
echo "PROJECT_LOCATION=$PROJ_LOC"
echo "PROJECT_ENDPOINT=$PROJ_ENDPOINT"

if (( PROJ_COUNT > 1 )); then
  echo "[i] Account has $PROJ_COUNT projects. Selected '$PROJ_NAME' (idx $PROJ_IDX)." >&2
fi

# ----------------------------------------------------------------------------
# 3. Project connections (AI Search, Cosmos, Storage, Fabric, AI Services, …)
# ----------------------------------------------------------------------------
echo "[i] Listing connections on project $PROJ_NAME (api-version=$CONNECTIONS_API_VERSION)…" >&2
CONN_RESP=$(az rest --method GET \
  --url "https://management.azure.com${PROJ_ID}/connections?api-version=${CONNECTIONS_API_VERSION}" \
  2>&1) || CONN_RC=$?
CONN_RC=${CONN_RC:-0}
if (( CONN_RC != 0 )); then
  echo "[!] Connections API failed (rc=$CONN_RC). Bump api-version or check RBAC." >&2
  echo "    Response: $(echo "$CONN_RESP" | head -c 240)" >&2
  CONNECTIONS_JSON='{"value":[]}'
else
  CONNECTIONS_JSON="$CONN_RESP"
fi
unset CONN_RC

CONN_COUNT=$(echo "$CONNECTIONS_JSON" | jq '.value | length')
echo "CONNECTION_COUNT=$CONN_COUNT"

# Categorize connections by category so the formatter can verdict each.
# Known categories the formatter cares about: AzureAISearch, CosmosDB,
# AzureStorageAccount, AzureBlob, FabricEngagement (Fabric Data Agent
# workspace), AIServices, AzureOpenAI, ApplicationInsights, KeyVault.
if (( CONN_COUNT > 0 )); then
  # Emit a per-connection block: CONNECTION_<n>_{NAME,CATEGORY,TARGET,AUTH,RESOURCE_ID}
  # RESOURCE_ID = metadata.ResourceId — REQUIRED by capabilityHost runtime
  # resolution (per Foundry capability-hosts doc). /add-capability-host blocks
  # if any chosen connection has an empty ResourceId.
  for k in $(seq 0 $((CONN_COUNT - 1))); do
    CN=$(echo "$CONNECTIONS_JSON" | jq -r ".value[$k].name")
    CC=$(echo "$CONNECTIONS_JSON" | jq -r ".value[$k].properties.category // \"unknown\"")
    CT=$(echo "$CONNECTIONS_JSON" | jq -r ".value[$k].properties.target // \"\"")
    CA=$(echo "$CONNECTIONS_JSON" | jq -r ".value[$k].properties.authType // \"unknown\"")
    CR=$(echo "$CONNECTIONS_JSON" | jq -r ".value[$k].properties.metadata.ResourceId // \"\"")
    echo "CONNECTION_$((k+1))_NAME=$CN"
    echo "CONNECTION_$((k+1))_CATEGORY=$CC"
    echo "CONNECTION_$((k+1))_TARGET=$CT"
    echo "CONNECTION_$((k+1))_AUTH=$CA"
    echo "CONNECTION_$((k+1))_RESOURCE_ID=$CR"
  done
  # Aggregate categories CSV for quick formatter consumption
  CATS=$(echo "$CONNECTIONS_JSON" | jq -r '[.value[].properties.category] | unique | join(",")')
  echo "CONNECTION_CATEGORIES=$CATS"
else
  echo "[!] Project has zero connections. Knowledge / Fabric / external data tools" >&2
  echo "    will not be reachable from agents until connections are added." >&2
fi

# ----------------------------------------------------------------------------
# 4. Capability hosts — TWO scopes (account-level + project-level)
# ----------------------------------------------------------------------------
# Per Foundry capability-hosts doc (verified against agents-3iq-ncus-2 real
# shape): both account-level AND project-level capabilityHosts matter.
#
#   account-level  → enables Agent Service at the account scope. Required as
#                    a prerequisite before a project-level one can be created
#                    (409 otherwise). Created bare via azd ai agent extension
#                    with ENABLE_CAPABILITY_HOST=true OR by /add-capability-host.
#   project-level  → THIS is what Agent Service actually reads for BYO bindings
#                    (threadStorageConnections / vectorStoreConnections /
#                    storageConnections / aiServicesConnections). Without it,
#                    agents fall back to Microsoft-managed default storage.
#
# Earlier versions of this script only probed the project scope, which silently
# hid the case "account caphost exists but project one missing" — i.e. the
# standard-agent-setup is half-done. Now both are probed and emitted as
# separate signals so the Python verdict can distinguish:
#   * neither   → ⚠ no caphost at any scope (full default)
#   * account   → ⚠ account caphost exists, project missing → BYO not active
#   * both      → ✅ (or ⚠ if BYO connections are partial / missing ResourceId)

# 4a. Account-level capability hosts
echo "[i] Listing account-level capability hosts on ${ACCT_NAME} (api-version=$CAPHOSTS_API_VERSION)…" >&2
ACCT_CAPH_RESP=$(az rest --method GET \
  --url "https://management.azure.com${ACCT_ID}/capabilityHosts?api-version=${CAPHOSTS_API_VERSION}" \
  2>&1) || ACCT_CAPH_RC=$?
ACCT_CAPH_RC=${ACCT_CAPH_RC:-0}
if (( ACCT_CAPH_RC != 0 )); then
  echo "[!] Account-level capabilityHosts API failed (rc=$ACCT_CAPH_RC). Treating as zero." >&2
  echo "    Response: $(echo "$ACCT_CAPH_RESP" | head -c 240)" >&2
  ACCT_CAPHOSTS_JSON='{"value":[]}'
else
  ACCT_CAPHOSTS_JSON="$ACCT_CAPH_RESP"
fi
unset ACCT_CAPH_RC

ACCT_CAPH_COUNT=$(echo "$ACCT_CAPHOSTS_JSON" | jq '.value | length')
echo "CAPHOST_ACCOUNT_COUNT=$ACCT_CAPH_COUNT"
if (( ACCT_CAPH_COUNT > 0 )); then
  for k in $(seq 0 $((ACCT_CAPH_COUNT - 1))); do
    HN=$(echo "$ACCT_CAPHOSTS_JSON" | jq -r ".value[$k].name")
    HK=$(echo "$ACCT_CAPHOSTS_JSON" | jq -r ".value[$k].properties.capabilityHostKind // \"unknown\"")
    HP=$(echo "$ACCT_CAPHOSTS_JSON" | jq -r ".value[$k].properties.provisioningState // \"unknown\"")
    HT=$(echo "$ACCT_CAPHOSTS_JSON" | jq -r "(.value[$k].properties.threadStorageConnections // []) | length")
    HV=$(echo "$ACCT_CAPHOSTS_JSON" | jq -r "(.value[$k].properties.vectorStoreConnections // []) | length")
    HS=$(echo "$ACCT_CAPHOSTS_JSON" | jq -r "(.value[$k].properties.storageConnections // []) | length")
    echo "CAPHOST_ACCOUNT_$((k+1))_NAME=$HN"
    echo "CAPHOST_ACCOUNT_$((k+1))_KIND=$HK"
    echo "CAPHOST_ACCOUNT_$((k+1))_PROV_STATE=$HP"
    echo "CAPHOST_ACCOUNT_$((k+1))_THREAD_CONN_COUNT=$HT"
    echo "CAPHOST_ACCOUNT_$((k+1))_VECTOR_CONN_COUNT=$HV"
    echo "CAPHOST_ACCOUNT_$((k+1))_STORAGE_CONN_COUNT=$HS"
  done
fi

# 4b. Project-level capability hosts (the one Agent Service actually reads)
echo "[i] Listing project-level capability hosts on ${PROJ_NAME} (api-version=$CAPHOSTS_API_VERSION)…" >&2
CAPH_RESP=$(az rest --method GET \
  --url "https://management.azure.com${PROJ_ID}/capabilityHosts?api-version=${CAPHOSTS_API_VERSION}" \
  2>&1) || CAPH_RC=$?
CAPH_RC=${CAPH_RC:-0}
if (( CAPH_RC != 0 )); then
  echo "[!] Project-level capabilityHosts API failed (rc=$CAPH_RC) — treating as zero." >&2
  echo "    Response: $(echo "$CAPH_RESP" | head -c 240)" >&2
  CAPHOSTS_JSON='{"value":[]}'
else
  CAPHOSTS_JSON="$CAPH_RESP"
fi
unset CAPH_RC

CAPH_COUNT=$(echo "$CAPHOSTS_JSON" | jq '.value | length')
echo "CAPHOST_PROJECT_COUNT=$CAPH_COUNT"
# Legacy alias: CAPHOST_COUNT now refers to project-level only (was always
# project-level before, just unlabeled). Keep emitting for any external
# consumer that grep's the old key.
echo "CAPHOST_COUNT=$CAPH_COUNT"
if (( CAPH_COUNT > 0 )); then
  for k in $(seq 0 $((CAPH_COUNT - 1))); do
    HN=$(echo "$CAPHOSTS_JSON" | jq -r ".value[$k].name")
    HK=$(echo "$CAPHOSTS_JSON" | jq -r ".value[$k].properties.capabilityHostKind // \"unknown\"")
    HP=$(echo "$CAPHOSTS_JSON" | jq -r ".value[$k].properties.provisioningState // \"unknown\"")
    # Per-binding connection NAMES (csv) — formatter checks each against
    # CONNECTION_<n>_NAME to verify ResourceId is populated.
    HT_NAMES=$(echo "$CAPHOSTS_JSON" | jq -r "(.value[$k].properties.threadStorageConnections // []) | join(\",\")")
    HV_NAMES=$(echo "$CAPHOSTS_JSON" | jq -r "(.value[$k].properties.vectorStoreConnections // []) | join(\",\")")
    HS_NAMES=$(echo "$CAPHOSTS_JSON" | jq -r "(.value[$k].properties.storageConnections // []) | join(\",\")")
    HA_NAMES=$(echo "$CAPHOSTS_JSON" | jq -r "(.value[$k].properties.aiServicesConnections // []) | join(\",\")")
    echo "CAPHOST_PROJECT_$((k+1))_NAME=$HN"
    echo "CAPHOST_PROJECT_$((k+1))_KIND=$HK"
    echo "CAPHOST_PROJECT_$((k+1))_PROV_STATE=$HP"
    echo "CAPHOST_PROJECT_$((k+1))_THREAD_CONNECTIONS=$HT_NAMES"
    echo "CAPHOST_PROJECT_$((k+1))_VECTOR_CONNECTIONS=$HV_NAMES"
    echo "CAPHOST_PROJECT_$((k+1))_STORAGE_CONNECTIONS=$HS_NAMES"
    echo "CAPHOST_PROJECT_$((k+1))_AISERVICES_CONNECTIONS=$HA_NAMES"
    # Legacy keys (kept for backwards compat with v0.26.0-initial formatter).
    echo "CAPHOST_$((k+1))_NAME=$HN"
    echo "CAPHOST_$((k+1))_KIND=$HK"
    echo "CAPHOST_$((k+1))_THREAD_COUNT=$(echo "$CAPHOSTS_JSON" | jq -r "(.value[$k].properties.threadStorageConnections // []) | length")"
    echo "CAPHOST_$((k+1))_VECTOR_COUNT=$(echo "$CAPHOSTS_JSON" | jq -r "(.value[$k].properties.vectorStoreConnections // []) | length")"
    echo "CAPHOST_$((k+1))_MEMORY_COUNT=0"  # memoryStoreConnections deprecated in 2026-03-01
  done
fi

# ----------------------------------------------------------------------------
# 5. Network injection (managed VNet / BYO VNet)
# ----------------------------------------------------------------------------
echo "[i] Probing networkInjections on account (api-version=$NETWORK_API_VERSION)…" >&2
NET_RESP=$(az rest --method GET \
  --url "https://management.azure.com${ACCT_ID}/networkInjections?api-version=${NETWORK_API_VERSION}" \
  2>&1) || NET_RC=$?
NET_RC=${NET_RC:-0}
if (( NET_RC != 0 )); then
  echo "[i] networkInjections API returned non-zero (rc=$NET_RC) — likely no injection" >&2
  echo "    on this account (public network class). Response: $(echo "$NET_RESP" | head -c 180)" >&2
  NET_JSON='{"value":[]}'
else
  NET_JSON="$NET_RESP"
fi
unset NET_RC

NET_COUNT=$(echo "$NET_JSON" | jq '.value | length')
echo "NETWORK_INJECTION_COUNT=$NET_COUNT"
if (( NET_COUNT > 0 )); then
  # First injection drives the classification
  NI_NAME=$(echo "$NET_JSON" | jq -r '.value[0].name')
  NI_SUBNET=$(echo "$NET_JSON" | jq -r '.value[0].properties.subnetArmId // ""')
  NI_USE_MAN=$(echo "$NET_JSON" | jq -r '.value[0].properties.useMicrosoftManagedNetwork // false')
  echo "NETWORK_INJECTION_NAME=$NI_NAME"
  echo "NETWORK_INJECTION_SUBNET=$NI_SUBNET"
  echo "NETWORK_INJECTION_USE_MICROSOFT_MANAGED=$NI_USE_MAN"
  if [[ "$NI_USE_MAN" == "true" ]]; then
    echo "NETWORK_CLASS=managed-vnet"
  elif [[ -n "$NI_SUBNET" ]]; then
    echo "NETWORK_CLASS=byo-vnet"
  else
    echo "NETWORK_CLASS=unknown-injection"
  fi
else
  # Fall back to publicNetworkAccess on the account
  if [[ "$PUB_NET_ACCESS" == "Disabled" ]]; then
    echo "NETWORK_CLASS=private-no-injection"
  else
    echo "NETWORK_CLASS=public"
  fi
fi

# ----------------------------------------------------------------------------
# 6. Model deployments inventory (cross-account, AIServices only)
# ----------------------------------------------------------------------------
echo "[i] Inventorying model deployments across AIServices accounts in $RG…" >&2
TOTAL_DEPLOYMENTS=0
OWN_ACCOUNT_DEPLOYMENTS=0
for i in $(seq 0 $((ACCOUNT_COUNT - 1))); do
  AN=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].name")
  AK=$(echo "$ACCOUNTS_JSON" | jq -r ".[$i].kind")
  [[ "$AK" != "AIServices" ]] && continue
  DEP_JSON=$(az cognitiveservices account deployment list \
    -g "$RG" -n "$AN" --subscription "$SUB" -o json 2>/dev/null || echo "[]")
  DEP_COUNT=$(echo "$DEP_JSON" | jq 'length')
  TOTAL_DEPLOYMENTS=$((TOTAL_DEPLOYMENTS + DEP_COUNT))
  [[ "$AN" == "$ACCT_NAME" ]] && OWN_ACCOUNT_DEPLOYMENTS=$DEP_COUNT
  if (( DEP_COUNT > 0 )); then
    NAMES=$(echo "$DEP_JSON" | jq -r '[.[].name] | join(",")')
    MODELS=$(echo "$DEP_JSON" | jq -r '[.[].properties.model.name] | join(",")')
    echo "DEPLOYMENT_ACCOUNT_${AN}_COUNT=$DEP_COUNT"
    echo "DEPLOYMENT_ACCOUNT_${AN}_NAMES=$NAMES"
    echo "DEPLOYMENT_ACCOUNT_${AN}_MODELS=$MODELS"
  fi
done
echo "DEPLOYMENT_TOTAL_COUNT=$TOTAL_DEPLOYMENTS"
echo "DEPLOYMENT_OWN_ACCOUNT_COUNT=$OWN_ACCOUNT_DEPLOYMENTS"
echo "DEPLOYMENT_OWN_ACCOUNT_NAME=$ACCT_NAME"

# ----------------------------------------------------------------------------
# 7. Hosted agents on the selected project (control plane — needs ai.azure.com)
# ----------------------------------------------------------------------------
if [[ -n "$PROJ_ENDPOINT" ]]; then
  echo "[i] Listing hosted agents via control plane $PROJ_ENDPOINT (api-version=$AGENTS_API_VERSION)…" >&2
  # F-28: must use --resource https://ai.azure.com (not management.azure.com).
  # Endpoint shape: `/agents` (Foundry hosted-agent collection — what `azd ai
  # agent` / agent.yaml provisions). NOT `/assistants`, which is the legacy
  # OpenAI Assistants-compatible surface (ephemeral, SDK-created objects with
  # a separate lifecycle and a different per-project collection).
  # Response envelope: OpenAI-pagination shape `{object, data:[...], first_id,
  # last_id, has_more}` — verified live 2026-06-15 against api-version=v1.
  # Each entry has `id` + `name` (both populated, name == id in current GA).
  # Header `Foundry-Features: HostedAgents=V1Preview` is harmless on GET but
  # kept for parity with mutating calls in rest-api.md.
  AGENTS_TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv 2>/dev/null || echo "")
  if [[ -n "$AGENTS_TOKEN" ]]; then
    AGENTS_URL="${PROJ_ENDPOINT%/}/agents?api-version=${AGENTS_API_VERSION}"
    AGENTS_RESP=$(curl -sS \
      -H "Authorization: Bearer $AGENTS_TOKEN" \
      -H "Foundry-Features: HostedAgents=V1Preview" \
      "$AGENTS_URL" 2>&1) || AGT_RC=$?
    AGT_RC=${AGT_RC:-0}
    if (( AGT_RC != 0 )); then
      echo "[!] Agents control-plane call failed (rc=$AGT_RC)." >&2
      echo "    Response: $(echo "$AGENTS_RESP" | head -c 240)" >&2
      AGENTS_JSON='{"data":[]}'
    else
      AGENTS_JSON="$AGENTS_RESP"
    fi
    unset AGT_RC
  else
    echo "[!] Could not acquire ai.azure.com token — skipping hosted-agent listing." >&2
    AGENTS_JSON='{"data":[]}'
  fi
else
  echo "[!] No project endpoint available — skipping hosted-agent listing." >&2
  AGENTS_JSON='{"data":[]}'
fi

AGT_COUNT=$(echo "$AGENTS_JSON" | jq '(.data // []) | length' 2>/dev/null || echo 0)
echo "AGENT_COUNT=$AGT_COUNT"
if (( AGT_COUNT > 0 )); then
  NAMES=$(echo "$AGENTS_JSON" | jq -r '[.data[].name // .data[].id] | join(",")' 2>/dev/null || echo "")
  echo "AGENT_NAMES=$NAMES"
fi

# ----------------------------------------------------------------------------
# 8. Quota signal (best-effort — tolerated empty)
# ----------------------------------------------------------------------------
echo "[i] Pulling account usages signal (best-effort)…" >&2
USAGE_JSON=$(az cognitiveservices usage list -l "$ACCT_LOC" --subscription "$SUB" -o json 2>/dev/null || echo "[]")
USAGE_COUNT=$(echo "$USAGE_JSON" | jq 'length' 2>/dev/null || echo 0)
echo "QUOTA_USAGE_RECORD_COUNT=$USAGE_COUNT"

# ----------------------------------------------------------------------------
# 9. Summary
# ----------------------------------------------------------------------------
echo "TOPOLOGY_STATUS=ok"
echo "TOPOLOGY_FOUNDRY_GRADE=true"
echo "TOPOLOGY_PROJECT_COUNT=$PROJ_COUNT"
echo "TOPOLOGY_CONNECTION_COUNT=$CONN_COUNT"
echo "TOPOLOGY_CAPHOST_PROJECT_COUNT=$CAPH_COUNT"
echo "TOPOLOGY_CAPHOST_ACCOUNT_COUNT=$ACCT_CAPH_COUNT"
echo "TOPOLOGY_CAPHOST_COUNT=$CAPH_COUNT"  # legacy alias for project count
echo "TOPOLOGY_NETWORK_INJECTION_COUNT=$NET_COUNT"
echo "TOPOLOGY_DEPLOYMENT_TOTAL=$TOTAL_DEPLOYMENTS"
echo "TOPOLOGY_AGENT_COUNT=$AGT_COUNT"
echo "[i] Discovery complete. Account=$ACCT_NAME Project=$PROJ_NAME Connections=$CONN_COUNT Hosts=${CAPH_COUNT}proj/${ACCT_CAPH_COUNT}acct Deployments=$TOTAL_DEPLOYMENTS Agents=$AGT_COUNT" >&2
