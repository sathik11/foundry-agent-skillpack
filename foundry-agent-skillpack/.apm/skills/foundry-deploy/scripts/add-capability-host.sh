#!/usr/bin/env bash
# /add-capability-host mutator — wire a Foundry project's capabilityHost
# (account-level prerequisite + project-level BYO bindings) per the contract
# in ../capability-host-bootstrap.md.
#
# This script DOES mutate Azure (PUT and optionally DELETE capabilityHosts).
# It is dry-run by default. Live mutation requires --no-dry-run.
#
# Usage:
#   ./add-capability-host.sh <sub> <rg> <account> <project> [flags]
#
# Connection-selection flags (one per binding role):
#   --thread-conn <name>       Cosmos DB connection (category=CosmosDb)
#   --vector-conn <name>       AI Search connection (category=CognitiveSearch)
#   --storage-conn <name>      Storage connection (category=AzureStorageAccount)
#   --aiservices-conn <name>   AI Services connection (optional)
#
# Bring-your-own EXISTING Azure resource flags (option B — create the Foundry
# connection inline when none of that category exists yet). When supplied, the
# script will PUT a project-scoped connection with metadata.ResourceId set to
# the ARM ID, deriving the endpoint `target` from the resource name. If a
# matching --<role>-conn name is also passed, that name is used; otherwise the
# script auto-derives <resource-basename>-conn.
#   --thread-resource-id <arm-id>    Cosmos DB account ARM ID  (Microsoft.DocumentDB/databaseAccounts)
#   --vector-resource-id <arm-id>    AI Search service ARM ID   (Microsoft.Search/searchServices)
#   --storage-resource-id <arm-id>   Storage account ARM ID     (Microsoft.Storage/storageAccounts)
#
# Behavioral flags:
#   --scope account|project|both   Default: both. Use 'account' to bootstrap
#                                  only the prerequisite; 'project' to add
#                                  the BYO bindings when account host already
#                                  exists.
#   --auto-pick                    If a category has exactly ONE connection in
#                                  the project, use it automatically. If
#                                  multiple, exit 2 with a picklist on stdout.
#                                  If zero, exit 3 with "no connection of
#                                  category X — create one first".
#   --force-recreate               If a same-name capabilityHost already
#                                  exists, DELETE it and recreate. Without
#                                  this flag, an existing host triggers
#                                  exit 4. The prompt's Step 5 requires
#                                  explicit user consent before passing this.
#   --grant-rbac                   Grant the project's SystemAssigned managed
#                                  identity the 6 data-plane + control-plane
#                                  roles capabilityHost provisioning REQUIRES
#                                  on the bound Cosmos / AI Search / Storage
#                                  resources. Runs BEFORE the capHost PUT.
#                                  Empirically: without these grants the
#                                  project capabilityHost provisioning ends
#                                  in provisioningState=Failed (the platform
#                                  bootstraps containers/indexes/blobs via
#                                  the project MI and the call stalls until
#                                  it gives up). The 6 grants (per MS Learn
#                                  standard-agent-setup Phase 3 + Phase 5):
#                                    Cosmos:   Cosmos DB Operator (control) +
#                                              Cosmos DB Built-in Data
#                                              Contributor (data, granted via
#                                              `az cosmosdb sql role
#                                              assignment create` — separate
#                                              command from regular RBAC)
#                                    Search:   Search Service Contributor +
#                                              Search Index Data Contributor
#                                    Storage:  Storage Account Contributor +
#                                              Storage Blob Data Owner
#                                  All grants are idempotent — re-running is
#                                  safe. RBAC propagation takes ~30s so the
#                                  script sleeps before the capHost PUT when
#                                  --grant-rbac was passed.
#   --no-dry-run                   Actually issue the PUT/DELETE/grant calls.
#                                  Default is dry-run: print the request
#                                  bodies and exit 5 without mutating.
#   --account-host-name <name>     Default: account-capability-host
#   --project-host-name <name>     Default: project-capability-host
#
# Exit codes:
#   0 — capabilityHost(s) created and verified
#   1 — fatal error (network, auth, malformed input)
#   2 — ambiguous connection selection (>1 candidate, no --thread/vector/storage-conn given)
#   3 — chosen connection has empty metadata.ResourceId (fix connection first)
#   4 — same-name capabilityHost already exists (re-run with --force-recreate)
#   5 — dry-run complete (no mutation issued)
#   6 — RBAC grant failed (caller lacks Microsoft.Authorization/roleAssignments/write)
set -euo pipefail

SUB="${1:?usage: $0 <sub> <rg> <account> <project> [flags]}"
RG="${2:?usage: $0 <sub> <rg> <account> <project> [flags]}"
ACCT="${3:?usage: $0 <sub> <rg> <account> <project> [flags]}"
PROJ="${4:?usage: $0 <sub> <rg> <account> <project> [flags]}"
shift 4

# ----------------------------------------------------------------------------
# Defaults + flag parse
# ----------------------------------------------------------------------------
THREAD_CONN=""
VECTOR_CONN=""
STORAGE_CONN=""
AISERVICES_CONN=""
THREAD_RES_ID=""
VECTOR_RES_ID=""
STORAGE_RES_ID=""
SCOPE="both"
AUTO_PICK=false
FORCE_RECREATE=false
GRANT_RBAC=false   # See --grant-rbac help text. Required for project capHost provisioning to succeed when project MI lacks data-plane roles on backing resources.
DRY_RUN=true   # SAFE DEFAULT — mutation requires explicit --no-dry-run
ACCT_HOST_NAME="account-capability-host"
PROJ_HOST_NAME="project-capability-host"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --thread-conn)         THREAD_CONN="$2"; shift 2 ;;
    --vector-conn)         VECTOR_CONN="$2"; shift 2 ;;
    --storage-conn)        STORAGE_CONN="$2"; shift 2 ;;
    --aiservices-conn)     AISERVICES_CONN="$2"; shift 2 ;;
    --thread-resource-id)  THREAD_RES_ID="$2"; shift 2 ;;
    --vector-resource-id)  VECTOR_RES_ID="$2"; shift 2 ;;
    --storage-resource-id) STORAGE_RES_ID="$2"; shift 2 ;;
    --scope)               SCOPE="$2"; shift 2 ;;
    --auto-pick)           AUTO_PICK=true; shift ;;
    --force-recreate)      FORCE_RECREATE=true; shift ;;
    --grant-rbac)          GRANT_RBAC=true; shift ;;
    --no-dry-run)          DRY_RUN=false; shift ;;
    --account-host-name)   ACCT_HOST_NAME="$2"; shift 2 ;;
    --project-host-name)   PROJ_HOST_NAME="$2"; shift 2 ;;
    *) echo "[x] Unknown flag: $1" >&2; exit 1 ;;
  esac
done

case "$SCOPE" in
  account|project|both) ;;
  *) echo "[x] --scope must be one of: account, project, both" >&2; exit 1 ;;
esac

CAPHOSTS_API_VERSION="2026-03-01"
CONNECTIONS_API_VERSION="2026-03-01"

ACCT_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.CognitiveServices/accounts/$ACCT"
PROJ_ID="${ACCT_ID}/projects/$PROJ"

echo "[i] /add-capability-host" >&2
echo "    subscription=$SUB" >&2
echo "    resource-group=$RG" >&2
echo "    account=$ACCT" >&2
echo "    project=$PROJ" >&2
echo "    scope=$SCOPE  auto-pick=$AUTO_PICK  force-recreate=$FORCE_RECREATE  grant-rbac=$GRANT_RBAC  dry-run=$DRY_RUN" >&2

# ----------------------------------------------------------------------------
# Step 1 — Pull project connections (needed for auto-pick + ResourceId verify)
# ----------------------------------------------------------------------------
echo "[i] Listing project connections (api-version=$CONNECTIONS_API_VERSION)…" >&2
CONN_RESP=$(az rest --method GET \
  --url "https://management.azure.com${PROJ_ID}/connections?api-version=${CONNECTIONS_API_VERSION}" \
  2>&1) || CONN_RC=$?
CONN_RC=${CONN_RC:-0}
if (( CONN_RC != 0 )); then
  echo "[x] Connections API failed (rc=$CONN_RC). Cannot proceed without connection list." >&2
  echo "    Response: $(echo "$CONN_RESP" | head -c 300)" >&2
  exit 1
fi
CONN_JSON="$CONN_RESP"

# Helper: list connection names of a given category, one per line.
# Args: $1=category
conn_names_of_category() {
  echo "$CONN_JSON" | jq -r --arg c "$1" '.value[] | select(.properties.category == $c) | .name'
}
# Helper: get metadata.ResourceId for a given connection name.
conn_resource_id() {
  echo "$CONN_JSON" | jq -r --arg n "$1" '.value[] | select(.name == $n) | .properties.metadata.ResourceId // ""'
}
# Helper: returns "yes" if a connection with this exact name exists already.
conn_exists() {
  echo "$CONN_JSON" | jq -r --arg n "$1" '[.value[] | select(.name == $n)] | length' | grep -q '^[1-9]' && echo yes || echo no
}

# ----------------------------------------------------------------------------
# Helpers for BYO-resource-id connection creation (option B)
# ----------------------------------------------------------------------------
# Validate the ARM ID provider segment matches the expected category.
validate_arm_provider() {
  local cat="$1" arm="$2" expected
  case "$cat" in
    CosmosDb)            expected="Microsoft.DocumentDB/databaseAccounts" ;;
    CognitiveSearch)     expected="Microsoft.Search/searchServices" ;;
    AzureStorageAccount) expected="Microsoft.Storage/storageAccounts" ;;
    *) return 1 ;;
  esac
  [[ "$arm" == *"/providers/${expected}/"* ]]
}

# Derive the deterministic endpoint `target` from ARM ID + category.
derive_target() {
  local cat="$1" arm="$2"
  local name="${arm##*/}"
  case "$cat" in
    CosmosDb)             echo "https://${name}.documents.azure.com:443/" ;;
    CognitiveSearch)      echo "https://${name}.search.windows.net" ;;
    AzureStorageAccount)  echo "https://${name}.blob.core.windows.net" ;;
    *) echo "" ;;
  esac
}

# GET the underlying Azure resource to read its location (needed for some
# categories' metadata.location). Falls back to ACCOUNT_LOCATION_HINT (the
# Foundry account's region) on read failure.
get_resource_location() {
  local cat="$1" arm="$2" api
  case "$cat" in
    CosmosDb)            api="2024-05-15" ;;
    CognitiveSearch)     api="2023-11-01" ;;
    AzureStorageAccount) api="2023-05-01" ;;
    *) echo ""; return 0 ;;
  esac
  local loc
  loc=$(az rest --method GET --url "https://management.azure.com${arm}?api-version=${api}" 2>/dev/null | jq -r '.location // ""')
  echo "$loc"
}

# Build the connection PUT body for a given category + ARM ID + location.
build_connection_body() {
  local cat="$1" arm="$2" location="$3"
  local target
  target=$(derive_target "$cat" "$arm")
  case "$cat" in
    CognitiveSearch)
      jq -n --arg cat "$cat" --arg target "$target" --arg rid "$arm" --arg loc "$location" \
        '{properties: {
            category: $cat, authType: "AAD", target: $target, isSharedToAll: true,
            metadata: { ApiType: "Azure", ApiVersion: "2024-05-01-preview", DeploymentApiVersion: "2023-11-01", ResourceId: $rid, location: $loc }
        }}'
      ;;
    CosmosDb)
      jq -n --arg cat "$cat" --arg target "$target" --arg rid "$arm" --arg loc "$location" \
        '{properties: {
            category: $cat, authType: "AAD", target: $target, isSharedToAll: true,
            metadata: { ApiType: "Azure", ResourceId: $rid, location: $loc }
        }}'
      ;;
    AzureStorageAccount)
      jq -n --arg cat "$cat" --arg target "$target" --arg rid "$arm" \
        '{properties: {
            category: $cat, authType: "AAD", target: $target, isSharedToAll: true,
            metadata: { ApiType: "Azure", ResourceId: $rid }
        }}'
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Step 2 — Resolve connection bindings (only needed if scope touches project)
#
# Resolution priority per role (thread / vector / storage):
#   1. --<role>-conn <name> matches an existing project connection → use it.
#   2. --<role>-resource-id <arm-id> provided (with or without --<role>-conn)
#      → plan to CREATE a new Foundry connection with metadata.ResourceId set.
#      If --<role>-conn was passed, use it as the new name; else derive from
#      the resource basename.
#   3. --auto-pick AND exactly one existing connection of the expected
#      category → use it.
#   4. --auto-pick AND zero candidates → exit 3 (hint: pass --<role>-resource-id).
#   5. --auto-pick AND multiple candidates → exit 2 (picklist on stdout).
#   6. Nothing → exit 1 with usage hint.
# ----------------------------------------------------------------------------

# Parallel arrays of connections to PUT in the mutation phase (project scope).
TO_CREATE_CONN_NAMES=()
TO_CREATE_CONN_BODIES=()
TO_CREATE_CONN_CATS=()

# Plan a connection-create operation for a given role + ARM ID. Sets the
# role's *_CONN variable to the resolved name. Does NOT mutate Azure (defer
# to Step 7a). Validates ARM provider and GETs location up-front so failures
# surface BEFORE dry-run.
plan_connection_create() {
  local role="$1" cat="$2" arm="$3"
  local var_conn="${role^^}_CONN"
  if ! validate_arm_provider "$cat" "$arm"; then
    echo "[x] --${role}-resource-id ARM ID does not match expected provider for category '$cat'." >&2
    echo "    Expected provider type: $(case $cat in CosmosDb) echo Microsoft.DocumentDB/databaseAccounts;; CognitiveSearch) echo Microsoft.Search/searchServices;; AzureStorageAccount) echo Microsoft.Storage/storageAccounts;; esac)" >&2
    echo "    Got: $arm" >&2
    exit 1
  fi
  local loc
  loc=$(get_resource_location "$cat" "$arm")
  if [[ -z "$loc" ]]; then
    echo "[x] Could not GET location for $arm — does the resource exist and do you have Reader rights on it?" >&2
    exit 1
  fi
  local body name requested="${!var_conn}"
  if [[ -n "$requested" ]]; then
    name="$requested"
  else
    name="${arm##*/}-conn"
  fi
  if [[ "$(conn_exists "$name")" == "yes" ]]; then
    echo "[x] --${role}-resource-id requested creating connection '$name' but a connection by that name already exists. Pick a different --${role}-conn name." >&2
    exit 1
  fi
  body=$(build_connection_body "$cat" "$arm" "$loc")
  TO_CREATE_CONN_NAMES+=("$name")
  TO_CREATE_CONN_BODIES+=("$body")
  TO_CREATE_CONN_CATS+=("$cat")
  printf -v "$var_conn" '%s' "$name"
  echo "[i] $role binding: PLAN CREATE connection '$name' (category=$cat, location=$loc, target=$(derive_target "$cat" "$arm"))" >&2
}

resolve_binding() {
  local role="$1" cat="$2"
  local var_conn="${role^^}_CONN"
  local var_res="${role^^}_RES_ID"
  local requested_conn="${!var_conn}"
  local requested_res="${!var_res}"

  # Case 1 — explicit conn name matches an existing connection.
  if [[ -n "$requested_conn" && "$(conn_exists "$requested_conn")" == "yes" ]]; then
    echo "[i] $role binding: existing connection '$requested_conn' (category=$cat)" >&2
    return 0
  fi

  # Case 2 — BYO resource-id provided → plan to create connection.
  if [[ -n "$requested_res" ]]; then
    plan_connection_create "$role" "$cat" "$requested_res"
    return 0
  fi

  # Case error — name provided but does not exist, and no resource-id given.
  if [[ -n "$requested_conn" ]]; then
    echo "[x] --${role}-conn '$requested_conn' not found in project connections, and no --${role}-resource-id provided." >&2
    echo "    Options:" >&2
    echo "      (a) pass an existing connection name as --${role}-conn" >&2
    echo "      (b) pass --${role}-resource-id <arm-id> so the script can create the Foundry connection from your existing Azure resource" >&2
    exit 1
  fi

  # Auto-pick path.
  if ! $AUTO_PICK; then
    echo "[x] $role binding not provided. Options:" >&2
    echo "      (a) --${role}-conn <existing-name>" >&2
    echo "      (b) --${role}-resource-id <arm-id>  (we'll create the Foundry connection from your existing resource)" >&2
    echo "      (c) --auto-pick                     (single-candidate auto-resolve)" >&2
    exit 1
  fi

  local candidates count
  candidates=$(conn_names_of_category "$cat")
  count=$(printf '%s\n' "$candidates" | grep -c . || true)
  if (( count == 0 )); then
    echo "[x] No connection of category '$cat' in project '$PROJ' and no --${role}-resource-id provided." >&2
    echo "    Either create a connection via the Foundry portal OR re-run with --${role}-resource-id <arm-id>." >&2
    exit 3
  elif (( count == 1 )); then
    local pick
    pick=$(printf '%s\n' "$candidates" | head -n 1)
    printf -v "$var_conn" '%s' "$pick"
    echo "[i] $role binding: auto-picked '$pick' (category=$cat, single candidate)" >&2
  else
    echo "[!] Multiple connections of category '$cat' — cannot auto-pick. Re-run with --${role}-conn <name>:" >&2
    printf '%s\n' "$candidates" | sed 's/^/      - /' >&2
    local idx=0
    while IFS= read -r n; do
      idx=$((idx+1))
      echo "PICKLIST_${role^^}_${idx}=$n"
    done <<<"$candidates"
    exit 2
  fi
}

if [[ "$SCOPE" == "project" || "$SCOPE" == "both" ]]; then
  resolve_binding thread  CosmosDb
  resolve_binding vector  CognitiveSearch
  resolve_binding storage AzureStorageAccount

  # Optional aiServices auto-pick (no error if absent — it's optional, and we
  # do NOT support BYO for AI Services via this script).
  if [[ -z "$AISERVICES_CONN" ]] && $AUTO_PICK; then
    AICAND=$(conn_names_of_category "AIServices" | head -n 1 || true)
    if [[ -n "$AICAND" ]]; then
      AISERVICES_CONN="$AICAND"
      echo "[i] aiServices binding: auto-picked '$AICAND' (optional)" >&2
    fi
  fi

  # Step 2b — Verify metadata.ResourceId on every chosen EXISTING connection.
  # Skip connections that are queued for creation in Step 7a (we set their
  # ResourceId ourselves, so no need to look it up in stale CONN_JSON).
  is_to_create() {
    local n="$1" x
    (( ${#TO_CREATE_CONN_NAMES[@]} == 0 )) && return 1
    for x in "${TO_CREATE_CONN_NAMES[@]}"; do
      [[ "$x" == "$n" ]] && return 0
    done
    return 1
  }
  for binding in "thread:$THREAD_CONN" "vector:$VECTOR_CONN" "storage:$STORAGE_CONN"; do
    role="${binding%%:*}"; name="${binding##*:}"
    [[ -z "$name" ]] && continue
    if is_to_create "$name"; then
      echo "[i] skipping ResourceId check for $role/'$name' (queued for creation in Step 7a)" >&2
      continue
    fi
    rid=$(conn_resource_id "$name")
    if [[ -z "$rid" ]]; then
      echo "[x] Connection '$name' ($role) has EMPTY metadata.ResourceId." >&2
      echo "    capabilityHost runtime would silently fall back to default storage." >&2
      echo "    Fix options:" >&2
      echo "      (a) recreate the connection via Foundry portal with the underlying resource" >&2
      echo "      (b) delete this connection and re-run with --${role}-resource-id <arm-id> to recreate it via this script" >&2
      echo "    See: foundry-deploy/capability-host-bootstrap.md → 'Required connections' section." >&2
      exit 3
    fi
    echo "[i] verified $role/'$name' ResourceId=${rid:0:80}…" >&2
  done
  if [[ -n "$AISERVICES_CONN" ]] && ! is_to_create "$AISERVICES_CONN"; then
    rid=$(conn_resource_id "$AISERVICES_CONN")
    if [[ -z "$rid" ]]; then
      echo "[x] AI Services connection '$AISERVICES_CONN' has empty metadata.ResourceId. Aborting." >&2
      exit 3
    fi
  fi
fi

# ----------------------------------------------------------------------------
# Step 3 — Detect existing hosts at each scope
# ----------------------------------------------------------------------------
echo "[i] Probing existing capabilityHosts (api-version=$CAPHOSTS_API_VERSION)…" >&2
ACCT_HOSTS_JSON=$(az rest --method GET \
  --url "https://management.azure.com${ACCT_ID}/capabilityHosts?api-version=${CAPHOSTS_API_VERSION}" 2>/dev/null \
  || echo '{"value":[]}')
PROJ_HOSTS_JSON=$(az rest --method GET \
  --url "https://management.azure.com${PROJ_ID}/capabilityHosts?api-version=${CAPHOSTS_API_VERSION}" 2>/dev/null \
  || echo '{"value":[]}')

ACCT_HOST_EXISTS=$(echo "$ACCT_HOSTS_JSON" | jq --arg n "$ACCT_HOST_NAME" '[.value[] | select(.name == $n)] | length')
PROJ_HOST_EXISTS=$(echo "$PROJ_HOSTS_JSON" | jq --arg n "$PROJ_HOST_NAME" '[.value[] | select(.name == $n)] | length')
ACCT_HOSTS_TOTAL=$(echo "$ACCT_HOSTS_JSON" | jq '.value | length')
PROJ_HOSTS_TOTAL=$(echo "$PROJ_HOSTS_JSON" | jq '.value | length')

echo "[i] existing hosts: account-scope=$ACCT_HOSTS_TOTAL (target name '$ACCT_HOST_NAME' present=$ACCT_HOST_EXISTS), project-scope=$PROJ_HOSTS_TOTAL (target name '$PROJ_HOST_NAME' present=$PROJ_HOST_EXISTS)" >&2

# ----------------------------------------------------------------------------
# Step 4 — Build request bodies
# ----------------------------------------------------------------------------
ACCT_BODY=$(jq -n '{properties: {capabilityHostKind: "Agents"}}')
# Build project body conditionally — only include aiServicesConnections if set
if [[ -n "$AISERVICES_CONN" ]]; then
  PROJ_BODY=$(jq -n \
    --arg t "$THREAD_CONN" --arg v "$VECTOR_CONN" --arg s "$STORAGE_CONN" --arg a "$AISERVICES_CONN" \
    '{properties: {
        capabilityHostKind: "Agents",
        threadStorageConnections: [$t],
        vectorStoreConnections:   [$v],
        storageConnections:       [$s],
        aiServicesConnections:    [$a]
    }}')
else
  PROJ_BODY=$(jq -n \
    --arg t "$THREAD_CONN" --arg v "$VECTOR_CONN" --arg s "$STORAGE_CONN" \
    '{properties: {
        capabilityHostKind: "Agents",
        threadStorageConnections: [$t],
        vectorStoreConnections:   [$v],
        storageConnections:       [$s]
    }}')
fi

# ----------------------------------------------------------------------------
# Step 4b — Plan RBAC grants (only if --grant-rbac was passed)
#
# For each role (thread/vector/storage) we need the backing resource's ARM ID
# in order to issue grants at the correct scope. Sources, in priority order:
#   1. --<role>-resource-id flag (BYO path — connection is being created from it)
#   2. metadata.ResourceId of the existing connection (CONN_JSON lookup)
# We never grant on the connection itself — we always grant on the underlying
# Azure data-plane resource (Cosmos account, Search service, Storage account).
# ----------------------------------------------------------------------------
THREAD_GRANT_ARM=""
VECTOR_GRANT_ARM=""
STORAGE_GRANT_ARM=""
if $GRANT_RBAC && { [[ "$SCOPE" == "project" ]] || [[ "$SCOPE" == "both" ]]; }; then
  resolve_grant_arm() {
    local role="$1"
    local var_conn="${role^^}_CONN"
    local var_res="${role^^}_RES_ID"
    local conn="${!var_conn}"
    local res="${!var_res}"
    if [[ -n "$res" ]]; then
      echo "$res"
      return 0
    fi
    if [[ -n "$conn" ]]; then
      conn_resource_id "$conn"
      return 0
    fi
    echo ""
  }
  THREAD_GRANT_ARM=$(resolve_grant_arm thread)
  VECTOR_GRANT_ARM=$(resolve_grant_arm vector)
  STORAGE_GRANT_ARM=$(resolve_grant_arm storage)
  for pair in "thread:$THREAD_GRANT_ARM" "vector:$VECTOR_GRANT_ARM" "storage:$STORAGE_GRANT_ARM"; do
    role="${pair%%:*}"; arm="${pair##*:}"
    if [[ -z "$arm" ]]; then
      echo "[x] --grant-rbac: cannot resolve backing ARM ID for $role role." >&2
      echo "    Pass --${role}-resource-id <arm-id> or use an existing connection with a populated metadata.ResourceId." >&2
      exit 1
    fi
  done
  echo "[i] RBAC grant plan (project MI → backing resources):" >&2
  echo "    thread  → $THREAD_GRANT_ARM" >&2
  echo "    vector  → $VECTOR_GRANT_ARM" >&2
  echo "    storage → $STORAGE_GRANT_ARM" >&2
fi

# ----------------------------------------------------------------------------
# Step 5 — Existence handling (409 protection)
# ----------------------------------------------------------------------------
WILL_DELETE_ACCT=false
WILL_DELETE_PROJ=false
WILL_CREATE_ACCT=false
WILL_CREATE_PROJ=false

if [[ "$SCOPE" == "account" || "$SCOPE" == "both" ]]; then
  if (( ACCT_HOST_EXISTS > 0 )); then
    if $FORCE_RECREATE; then
      WILL_DELETE_ACCT=true; WILL_CREATE_ACCT=true
    else
      echo "[!] Account capabilityHost '$ACCT_HOST_NAME' already exists. Skipping (re-run with --force-recreate to replace)." >&2
      [[ "$SCOPE" == "account" ]] && exit 4
    fi
  else
    WILL_CREATE_ACCT=true
  fi
fi

if [[ "$SCOPE" == "project" || "$SCOPE" == "both" ]]; then
  # Project requires account host first
  if (( ACCT_HOST_EXISTS == 0 )) && ! $WILL_CREATE_ACCT; then
    echo "[!] Project capabilityHost requires an account-level capabilityHost as a prerequisite." >&2
    echo "    No account-level host named '$ACCT_HOST_NAME' exists. Re-run with --scope both (the script will create the account host first)." >&2
    exit 1
  fi
  if (( PROJ_HOST_EXISTS > 0 )); then
    if $FORCE_RECREATE; then
      WILL_DELETE_PROJ=true; WILL_CREATE_PROJ=true
    else
      echo "[!] Project capabilityHost '$PROJ_HOST_NAME' already exists. Skipping (re-run with --force-recreate to replace)." >&2
      [[ "$SCOPE" == "project" ]] && exit 4
    fi
  else
    WILL_CREATE_PROJ=true
  fi
fi

# ----------------------------------------------------------------------------
# Step 6 — Dry-run summary
# ----------------------------------------------------------------------------
echo "" >&2
echo "=== Planned operations ===" >&2
if (( ${#TO_CREATE_CONN_NAMES[@]} > 0 )); then
  echo "  project connections to CREATE: ${#TO_CREATE_CONN_NAMES[@]}" >&2
  for i in "${!TO_CREATE_CONN_NAMES[@]}"; do
    echo "    - ${TO_CREATE_CONN_NAMES[$i]}  (category=${TO_CREATE_CONN_CATS[$i]})" >&2
  done
fi
echo "  account delete: $WILL_DELETE_ACCT  account create: $WILL_CREATE_ACCT  ($ACCT_HOST_NAME)" >&2
echo "  project delete: $WILL_DELETE_PROJ  project create: $WILL_CREATE_PROJ  ($PROJ_HOST_NAME)" >&2
if $GRANT_RBAC && { [[ "$SCOPE" == "project" ]] || [[ "$SCOPE" == "both" ]]; }; then
  echo "  RBAC grants (project MI on backing resources, idempotent):" >&2
  echo "    Cosmos DB Operator                                  → $THREAD_GRANT_ARM" >&2
  echo "    Cosmos DB Built-in Data Contributor (data plane)    → $THREAD_GRANT_ARM" >&2
  echo "    Search Service Contributor                          → $VECTOR_GRANT_ARM" >&2
  echo "    Search Index Data Contributor                       → $VECTOR_GRANT_ARM" >&2
  echo "    Storage Account Contributor                         → $STORAGE_GRANT_ARM" >&2
  echo "    Storage Blob Data Owner                             → $STORAGE_GRANT_ARM" >&2
fi
echo "" >&2
if (( ${#TO_CREATE_CONN_NAMES[@]} > 0 )); then
  echo "--- planned connection CREATE PUT bodies (project scope) ---" >&2
  for i in "${!TO_CREATE_CONN_NAMES[@]}"; do
    echo "PUT https://management.azure.com${PROJ_ID}/connections/${TO_CREATE_CONN_NAMES[$i]}?api-version=${CONNECTIONS_API_VERSION}" >&2
    echo "${TO_CREATE_CONN_BODIES[$i]}" | jq . >&2
  done
fi
if $WILL_CREATE_ACCT; then
  echo "--- account-level PUT body ---" >&2
  echo "$ACCT_BODY" | jq . >&2
fi
if $WILL_CREATE_PROJ; then
  echo "--- project-level PUT body ---" >&2
  echo "$PROJ_BODY" | jq . >&2
fi
echo "" >&2

if $DRY_RUN; then
  echo "[i] DRY-RUN complete. No mutations issued." >&2
  echo "    Re-run with --no-dry-run to apply." >&2
  echo "DRY_RUN_STATUS=ok"
  echo "CONNECTIONS_TO_CREATE_COUNT=${#TO_CREATE_CONN_NAMES[@]}"
  for i in "${!TO_CREATE_CONN_NAMES[@]}"; do
    [[ -z "${TO_CREATE_CONN_NAMES[$i]:-}" ]] && continue
    echo "CONNECTION_TO_CREATE_$((i+1))_NAME=${TO_CREATE_CONN_NAMES[$i]}"
    echo "CONNECTION_TO_CREATE_$((i+1))_CATEGORY=${TO_CREATE_CONN_CATS[$i]}"
  done
  echo "WILL_DELETE_ACCT=$WILL_DELETE_ACCT"
  echo "WILL_CREATE_ACCT=$WILL_CREATE_ACCT"
  echo "WILL_DELETE_PROJ=$WILL_DELETE_PROJ"
  echo "WILL_CREATE_PROJ=$WILL_CREATE_PROJ"
  exit 5
fi

# ----------------------------------------------------------------------------
# Step 7 — Mutations + polling
# ----------------------------------------------------------------------------
# Helper: PUT and poll provisioningState until terminal. Args: $1=url $2=body-file
put_and_poll() {
  local url="$1" body_file="$2" label="$3"
  echo "[i] PUT $label → $url" >&2
  local resp rc
  resp=$(az rest --method PUT --url "$url" --headers "Content-Type=application/json" --body "@$body_file" 2>&1) || rc=$?
  rc=${rc:-0}
  if (( rc != 0 )); then
    echo "[x] PUT failed (rc=$rc): $(echo "$resp" | head -c 400)" >&2
    return 1
  fi
  echo "[i] PUT accepted. Polling provisioningState (timeout ~3min)…" >&2
  for i in $(seq 1 36); do  # 36 * 5s = 180s
    sleep 5
    local state
    state=$(az rest --method GET --url "$url" 2>/dev/null | jq -r '.properties.provisioningState // "unknown"')
    case "$state" in
      Succeeded) echo "[+] $label → Succeeded (after ${i}x5s)" >&2; return 0 ;;
      Failed|Canceled) echo "[x] $label → $state" >&2; return 1 ;;
      *) echo "[.] $label provisioningState=$state (poll $i/36)" >&2 ;;
    esac
  done
  echo "[x] $label polling timed out (3min). Check Azure portal." >&2
  return 1
}

delete_and_wait() {
  local url="$1" label="$2"
  echo "[i] DELETE $label → $url" >&2
  az rest --method DELETE --url "$url" 2>&1 | head -c 400 >&2 || true
  # Poll GET until 404
  for i in $(seq 1 24); do
    sleep 5
    if ! az rest --method GET --url "$url" >/dev/null 2>&1; then
      echo "[+] $label deletion confirmed (after ${i}x5s)" >&2
      return 0
    fi
    echo "[.] $label still present (poll $i/24)" >&2
  done
  echo "[x] $label deletion polling timed out (2min)." >&2
  return 1
}

ACCT_HOST_URL="https://management.azure.com${ACCT_ID}/capabilityHosts/${ACCT_HOST_NAME}?api-version=${CAPHOSTS_API_VERSION}"
PROJ_HOST_URL="https://management.azure.com${PROJ_ID}/capabilityHosts/${PROJ_HOST_NAME}?api-version=${CAPHOSTS_API_VERSION}"

ACCT_BODY_FILE=$(mktemp /tmp/caphost-acct.XXXXXX.json)
PROJ_BODY_FILE=$(mktemp /tmp/caphost-proj.XXXXXX.json)
trap 'rm -f "$ACCT_BODY_FILE" "$PROJ_BODY_FILE"' EXIT
echo "$ACCT_BODY" > "$ACCT_BODY_FILE"
echo "$PROJ_BODY" > "$PROJ_BODY_FILE"

# ----------------------------------------------------------------------------
# Step 7a — Create any project connections requested via --<role>-resource-id
# BEFORE touching capabilityHosts. CapHost PUT will fail if any referenced
# connection name doesn't exist yet, so this must run first.
# Connections are not async — PUT returns the final state directly; we GET
# back once to confirm and log the ResourceId we set.
# ----------------------------------------------------------------------------
for i in "${!TO_CREATE_CONN_NAMES[@]}"; do
  [[ -z "${TO_CREATE_CONN_NAMES[$i]:-}" ]] && continue
  cname="${TO_CREATE_CONN_NAMES[$i]}"
  cbody="${TO_CREATE_CONN_BODIES[$i]}"
  ccat="${TO_CREATE_CONN_CATS[$i]}"
  curl="https://management.azure.com${PROJ_ID}/connections/${cname}?api-version=${CONNECTIONS_API_VERSION}"
  cfile=$(mktemp /tmp/conn-XXXXXX.json)
  echo "$cbody" > "$cfile"
  echo "[i] PUT connection $cname (category=$ccat) → $curl" >&2
  if ! resp=$(az rest --method PUT --url "$curl" --headers "Content-Type=application/json" --body "@$cfile" 2>&1); then
    rm -f "$cfile"
    echo "[x] Connection PUT failed for '$cname': $(echo "$resp" | head -c 400)" >&2
    exit 1
  fi
  rm -f "$cfile"
  # Verify back: read what landed and confirm metadata.ResourceId matches our intent.
  vrid=$(az rest --method GET --url "$curl" 2>/dev/null | jq -r '.properties.metadata.ResourceId // ""')
  if [[ -z "$vrid" ]]; then
    echo "[x] Connection '$cname' PUT succeeded but verification GET returned empty metadata.ResourceId. Aborting before capHost PUT." >&2
    exit 1
  fi
  echo "[+] connection '$cname' created (ResourceId=${vrid:0:80}…)" >&2
done

# ----------------------------------------------------------------------------
# Step 7b — Grant project MI the 6 data-plane + control-plane roles on the
# backing resources (only if --grant-rbac was passed). This runs AFTER any
# BYO connections are created (so metadata.ResourceId lookups work) and
# BEFORE the capabilityHost PUT (since the platform uses these grants during
# capHost provisioning — without them, provisioningState=Failed).
#
# Idempotency: each grant is checked for an "exists" error response and
# treated as success. Re-running the command is safe.
#
# Cosmos data-plane role uses a different CLI surface (`az cosmosdb sql role
# assignment create`) than ARM role assignments — it's stored on the Cosmos
# account itself, not in Microsoft.Authorization/roleAssignments.
# ----------------------------------------------------------------------------
GRANTS_COUNT=0
GRANT_RBAC_STATUS=skipped
if $GRANT_RBAC && { [[ "$SCOPE" == "project" ]] || [[ "$SCOPE" == "both" ]]; }; then
  echo "" >&2
  echo "=== Step 7b — Granting project MI data-plane RBAC ===" >&2
  # 1) Get project MI principalId (object ID).
  PROJ_MI_PRINCIPAL=$(az rest --method GET \
    --url "https://management.azure.com${PROJ_ID}?api-version=${CAPHOSTS_API_VERSION}" 2>/dev/null \
    | jq -r '.identity.principalId // ""')
  if [[ -z "$PROJ_MI_PRINCIPAL" || "$PROJ_MI_PRINCIPAL" == "null" ]]; then
    echo "[x] Could not resolve project SystemAssigned MI principalId. Project may lack systemAssigned identity." >&2
    exit 6
  fi
  echo "[i] project MI principalId=$PROJ_MI_PRINCIPAL" >&2

  # ARM role grant helper. Treats already-exists as success.
  grant_arm_role() {
    local mi="$1" role="$2" scope="$3" label="$4"
    local out rc=0
    out=$(az role assignment create \
      --assignee-object-id "$mi" \
      --assignee-principal-type ServicePrincipal \
      --role "$role" \
      --scope "$scope" 2>&1) || rc=$?
    if (( rc == 0 )); then
      echo "[+] granted '$role' on $label" >&2
      GRANTS_COUNT=$((GRANTS_COUNT+1))
      return 0
    fi
    if echo "$out" | grep -qi "RoleAssignmentExists\|already exists"; then
      echo "[=] '$role' already granted on $label" >&2
      GRANTS_COUNT=$((GRANTS_COUNT+1))
      return 0
    fi
    echo "[x] grant FAILED '$role' on $label:" >&2
    echo "    $(echo "$out" | head -c 400)" >&2
    return 1
  }

  # Cosmos DB Built-in Data Contributor uses a SEPARATE CLI surface.
  # roleDefinitionId 00000000-0000-0000-0000-000000000002 is the well-known
  # built-in Data Contributor at SQL data-plane scope.
  grant_cosmos_data_role() {
    local mi="$1" cosmos_arm="$2"
    local cosmos_name cosmos_rg out rc=0
    cosmos_name="${cosmos_arm##*/}"
    cosmos_rg=$(echo "$cosmos_arm" | sed -E 's|.*/resourceGroups/([^/]+)/.*|\1|')
    out=$(az cosmosdb sql role assignment create \
      --account-name "$cosmos_name" \
      --resource-group "$cosmos_rg" \
      --scope "/" \
      --principal-id "$mi" \
      --role-definition-id 00000000-0000-0000-0000-000000000002 2>&1) || rc=$?
    if (( rc == 0 )); then
      echo "[+] granted Cosmos data-plane 'Built-in Data Contributor' on $cosmos_name" >&2
      GRANTS_COUNT=$((GRANTS_COUNT+1))
      return 0
    fi
    if echo "$out" | grep -qi "already exists\|conflict"; then
      echo "[=] Cosmos data-plane 'Built-in Data Contributor' already granted on $cosmos_name" >&2
      GRANTS_COUNT=$((GRANTS_COUNT+1))
      return 0
    fi
    echo "[x] grant FAILED Cosmos data-plane on $cosmos_name:" >&2
    echo "    $(echo "$out" | head -c 400)" >&2
    return 1
  }

  # Issue all 6 grants.
  grant_arm_role    "$PROJ_MI_PRINCIPAL" "Cosmos DB Operator"                  "$THREAD_GRANT_ARM"  "$(basename "$THREAD_GRANT_ARM")"  || exit 6
  grant_cosmos_data_role "$PROJ_MI_PRINCIPAL" "$THREAD_GRANT_ARM"                                                                       || exit 6
  grant_arm_role    "$PROJ_MI_PRINCIPAL" "Search Service Contributor"          "$VECTOR_GRANT_ARM"  "$(basename "$VECTOR_GRANT_ARM")"  || exit 6
  grant_arm_role    "$PROJ_MI_PRINCIPAL" "Search Index Data Contributor"       "$VECTOR_GRANT_ARM"  "$(basename "$VECTOR_GRANT_ARM")"  || exit 6
  grant_arm_role    "$PROJ_MI_PRINCIPAL" "Storage Account Contributor"         "$STORAGE_GRANT_ARM" "$(basename "$STORAGE_GRANT_ARM")" || exit 6
  grant_arm_role    "$PROJ_MI_PRINCIPAL" "Storage Blob Data Owner"             "$STORAGE_GRANT_ARM" "$(basename "$STORAGE_GRANT_ARM")" || exit 6
  GRANT_RBAC_STATUS=ok
  echo "[i] all 6 grants landed. Sleeping 30s for RBAC propagation before capHost PUT…" >&2
  sleep 30
fi

if $WILL_DELETE_ACCT; then
  # Account delete cascades: must delete project host first if it exists
  if (( PROJ_HOST_EXISTS > 0 )); then
    delete_and_wait "$PROJ_HOST_URL" "project capabilityHost (cascading delete)" || exit 1
    PROJ_HOST_EXISTS=0
    WILL_DELETE_PROJ=false
  fi
  delete_and_wait "$ACCT_HOST_URL" "account capabilityHost" || exit 1
fi
if $WILL_CREATE_ACCT; then
  put_and_poll "$ACCT_HOST_URL" "$ACCT_BODY_FILE" "account capabilityHost" || exit 1
fi
if $WILL_DELETE_PROJ; then
  delete_and_wait "$PROJ_HOST_URL" "project capabilityHost" || exit 1
fi
if $WILL_CREATE_PROJ; then
  put_and_poll "$PROJ_HOST_URL" "$PROJ_BODY_FILE" "project capabilityHost" || exit 1
fi

# ----------------------------------------------------------------------------
# Step 8 — Verification GETs
# ----------------------------------------------------------------------------
echo "" >&2
echo "=== Verification ===" >&2
ACCT_VERIFY=$(az rest --method GET --url "$ACCT_HOST_URL" 2>/dev/null \
  | jq -r '"  account: name=\(.name) kind=\(.properties.capabilityHostKind) state=\(.properties.provisioningState)"' \
  || echo "  account: (not found — unexpected)")
echo "$ACCT_VERIFY" >&2
PROJ_VERIFY=$(az rest --method GET --url "$PROJ_HOST_URL" 2>/dev/null)
if [[ -n "$PROJ_VERIFY" && "$PROJ_VERIFY" != "null" ]]; then
  echo "  project: name=$(echo "$PROJ_VERIFY" | jq -r .name) state=$(echo "$PROJ_VERIFY" | jq -r .properties.provisioningState)" >&2
  echo "    thread=$(echo "$PROJ_VERIFY"  | jq -r '.properties.threadStorageConnections | join(",")')" >&2
  echo "    vector=$(echo "$PROJ_VERIFY"  | jq -r '.properties.vectorStoreConnections   | join(",")')" >&2
  echo "    storage=$(echo "$PROJ_VERIFY" | jq -r '.properties.storageConnections       | join(",")')" >&2
fi

echo "ADD_CAPHOST_STATUS=ok"
echo "ACCOUNT_HOST_NAME=$ACCT_HOST_NAME"
echo "PROJECT_HOST_NAME=$PROJ_HOST_NAME"
[[ -n "$THREAD_CONN" ]]      && echo "PROJECT_THREAD_CONN=$THREAD_CONN"
[[ -n "$VECTOR_CONN" ]]      && echo "PROJECT_VECTOR_CONN=$VECTOR_CONN"
[[ -n "$STORAGE_CONN" ]]     && echo "PROJECT_STORAGE_CONN=$STORAGE_CONN"
[[ -n "$AISERVICES_CONN" ]]  && echo "PROJECT_AISERVICES_CONN=$AISERVICES_CONN"
echo "GRANT_RBAC_STATUS=$GRANT_RBAC_STATUS"
echo "GRANTS_COUNT=$GRANTS_COUNT"
echo "[+] /add-capability-host complete. Re-run /assess-project to verify ⚠ → ✅." >&2
