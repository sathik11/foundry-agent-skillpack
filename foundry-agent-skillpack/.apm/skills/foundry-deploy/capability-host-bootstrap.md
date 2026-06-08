# Capability host bootstrap — bring-your-own thread / vector / storage

> Reference for the `/add-capability-host` prompt and the
> `scripts/add-capability-host.sh` mutator. Read this before invoking either.
> Covers the REST contract, two-scope ordering rule, connection prerequisites,
> idempotency contract, RBAC matrix, and verification GETs.

## Why this exists

Microsoft Foundry's Agent Service has two operating modes:

1. **Default platform-managed state.** No capability host bound. Threads,
   vector indexes, and file uploads land in Microsoft-managed storage inside
   the Foundry account. Quick to start, no BYO resources, no extra RBAC. The
   `/assess-project` rubric flags this with ⚠ (not ❌) — it's supported, just
   not what most production deployments want.
2. **Bring-your-own (BYO) capability host.** Agent Service writes thread
   history to **your** Azure Cosmos DB, vector indexes to **your** Azure AI
   Search, and file blobs to **your** Azure Storage. Required for any
   production scenario that needs sovereignty, retention control, or
   integration with non-agent analytics on the same data.

`/add-capability-host` is the **only supported path in the skillpack** to
wire mode (2). It is intentionally NOT folded into `/prepare-deploy` or
`azd up`:

- `/prepare-deploy` runs against a pre-existing project topology and never
  creates Azure resources outside the agent's container.
- The `azd ai agent` extension scaffolds with `ENABLE_CAPABILITY_HOST=false`
  because azd doesn't provision the prerequisite Cosmos / AI Search / Storage
  resources or the connections that bind them. The `azd up` happy path
  gives you mode (1). Run `/add-capability-host` after `azd up` to upgrade.

## The REST shape

Capability hosts are first-class resources under `Microsoft.CognitiveServices`
at **two scopes**:

```text
# Account-level (prerequisite — must exist before project-level)
PUT https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}
    /providers/Microsoft.CognitiveServices/accounts/{account}
    /capabilityHosts/{host-name}
    ?api-version=2026-03-01

# Project-level (this is what Agent Service reads at runtime)
PUT https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}
    /providers/Microsoft.CognitiveServices/accounts/{account}
    /projects/{project}/capabilityHosts/{host-name}
    ?api-version=2026-03-01
```

Account-level body (bare — no connections bound):

```json
{
  "properties": {
    "capabilityHostKind": "Agents"
  }
}
```

Project-level body (full BYO):

```json
{
  "properties": {
    "capabilityHostKind": "Agents",
    "threadStorageConnections":  ["<cosmos-connection-name>"],
    "vectorStoreConnections":    ["<aisearch-connection-name>"],
    "storageConnections":        ["<storage-connection-name>"],
    "aiServicesConnections":     ["<aoai-connection-name>"]
  }
}
```

`aiServicesConnections` is optional and only needed if your project does not
already have a default AI Services connection (rare — the Foundry account
usually provides one implicitly).

### Naming convention

The skillpack uses these names (matching the Microsoft docs samples):

| Scope     | Name                       |
|-----------|----------------------------|
| Account   | `account-capability-host`  |
| Project   | `project-capability-host`  |

These are conventional, not required by the API, but the
`/add-capability-host` script and verification GETs assume them. If you have
an existing host under a different name (e.g. `default` from azd), the
discover script will surface it and `/add-capability-host` will refuse to
create a second one (one host per scope — see *Idempotency* below).

## Two-scope ordering rule

**The account-level capability host MUST exist before the project-level one
can be created.** The API rejects project-level creation with `409 Conflict`
if no account-level host is present. Order:

1. `PUT` account-level → poll for `provisioningState: Succeeded`
2. `PUT` project-level → poll for `provisioningState: Succeeded`

The script handles this automatically: if `--scope project` is requested
and the account-level host is missing, it creates a bare account-level host
first (with explicit log line).

## Required connections — every one needs `metadata.ResourceId`

The connection categories the project capability host references are:

| Role            | Category               | Connection target                   |
|-----------------|------------------------|-------------------------------------|
| Thread storage  | `CosmosDb`             | Cosmos DB account (SQL API)         |
| Vector store    | `CognitiveSearch`      | Azure AI Search service             |
| Blob storage    | `AzureStorageAccount`  | Storage account (Blob endpoint)     |
| AI Services     | `AIServices`           | Foundry account (usually implicit)  |

For each of these, the connection **MUST** have `properties.metadata.ResourceId`
populated with the full ARM resource ID of the backing resource. If the field
is empty, the capability-host PUT succeeds but the runtime fails to resolve
the binding (silent — the Agent Service falls back to platform default).

The discover script now emits `CONNECTION_<n>_RESOURCE_ID=` for every
connection so `/add-capability-host` can verify upstream before issuing the
PUT. If any chosen connection has an empty `ResourceId`, the script exits
with rc=3 and tells you which connection to fix first.

To populate `ResourceId` on an existing connection that lacks it, the
supported path is to delete and recreate the connection via Azure portal
(Foundry project → Settings → Connected resources → +Add) — the portal
flow always sets `ResourceId`. Programmatic creation via REST/SDK must
explicitly set `properties.metadata.ResourceId` to the ARM ID of the target.

## Bring-your-own existing Azure resource (inline connection create)

When a project has **zero** connections of a category but you already have a
standing Cosmos / AI Search / Storage resource you want to bind, the script
will create the Foundry connection inline before wiring the capability host
— driven by these flags on `add-capability-host.sh`:

| Flag                       | Backing ARM provider                       | Connection category produced |
|----------------------------|--------------------------------------------|------------------------------|
| `--thread-resource-id`     | `Microsoft.DocumentDB/databaseAccounts`    | `CosmosDb`                   |
| `--vector-resource-id`     | `Microsoft.Search/searchServices`          | `CognitiveSearch`            |
| `--storage-resource-id`    | `Microsoft.Storage/storageAccounts`        | `AzureStorageAccount`        |

The script validates the ARM ID's provider segment matches the expected one
for the role and aborts with a clear message if not. It then:

1. GETs the underlying Azure resource to read its `location` (Cosmos and AI
   Search bake `metadata.location` into the connection; Storage does not).
2. Derives a connection name (`<basename>-conn`) and a deterministic
   endpoint target:
   - Cosmos: `https://<name>.documents.azure.com:443/`
   - AI Search: `https://<name>.search.windows.net`
   - Storage: `https://<name>.blob.core.windows.net`
3. Builds a per-category PUT body matching the live Foundry-portal shape:

```json
// Cosmos (3 metadata keys)
{
  "properties": {
    "category": "CosmosDb",
    "authType": "AAD",
    "target": "https://<cosmos>.documents.azure.com:443/",
    "isSharedToAll": true,
    "metadata": {
      "ApiType": "Azure",
      "ResourceId": "/subscriptions/.../Microsoft.DocumentDB/databaseAccounts/<cosmos>",
      "location": "East US"
    }
  }
}

// AI Search (4 metadata keys — unique in needing ApiVersion + DeploymentApiVersion)
{
  "properties": {
    "category": "CognitiveSearch",
    "authType": "AAD",
    "target": "https://<search>.search.windows.net",
    "isSharedToAll": true,
    "metadata": {
      "ApiType": "Azure",
      "ApiVersion": "2024-05-01-preview",
      "DeploymentApiVersion": "2023-11-01",
      "ResourceId": "/subscriptions/.../Microsoft.Search/searchServices/<search>",
      "location": "East US"
    }
  }
}

// Storage (2 metadata keys — no location)
{
  "properties": {
    "category": "AzureStorageAccount",
    "authType": "AAD",
    "target": "https://<storage>.blob.core.windows.net",
    "isSharedToAll": true,
    "metadata": {
      "ApiType": "Azure",
      "ResourceId": "/subscriptions/.../Microsoft.Storage/storageAccounts/<storage>"
    }
  }
}
```

4. In `--no-dry-run` mode, PUTs each planned connection (Step 7a of the
   script) and re-GETs it to confirm `metadata.ResourceId` is populated;
   aborts before the capHost PUT if any verification fails.
5. Then proceeds to the capHost PUTs, referencing the freshly-created
   connection names in `threadStorageConnections` / `vectorStoreConnections`
   / `storageConnections`.

**aiServices is intentionally out of scope for inline create.** The Foundry
account usually provides one implicitly, and the cases where it doesn't are
rare enough that hand-crafting the connection in the portal is the safer
path.

**Mixing strategies is supported.** You can pass `--thread-conn` (use
existing) for one role and `--vector-resource-id` (inline create) for
another in the same invocation — each role resolves independently.

### Resolution priority per role

For each of `thread` / `vector` / `storage`, the script picks one of these
in order:

1. `--<role>-conn <name>` matching an existing connection of the right
   category → use existing.
2. `--<role>-resource-id <arm-id>` → plan inline create.
3. Auto-pick when exactly one connection of the category exists (no
   ambiguity) → use existing.
4. Multiple candidates, no `--<role>-conn` → exit `2` (picklist).
5. Zero candidates, no `--<role>-resource-id` → exit `1` (no binding possible).

The `/add-capability-host` prompt re-engages the user on exit `1` with the
two-option choice: portal-create or paste an ARM ID.

## Idempotency — there is no UPDATE, only DELETE + CREATE

`PUT` against an existing capability host name returns `409 Conflict`. The
API does not support in-place mutation of `threadStorageConnections` etc.
To change bindings, you **delete** the host and **recreate** it.

Consequence: `/add-capability-host` is **not idempotent by default**. The
two ways to handle existing hosts:

- Default: the script detects a same-name host and exits with rc=4
  (`already-exists`). You can re-run with `--scope account` or `--scope
  project` to skip the one that already exists.
- `--force-recreate`: the script `DELETE`s the existing host, polls for
  the deletion to complete, then `PUT`s the new one. This requires
  **explicit consent** in the prompt — the dry-run shows you the delete
  surface before you confirm.

## RBAC

There are **two distinct RBAC dimensions** for capability host bootstrap.
Both must be in place before the project capabilityHost PUT or it will
silently fail.

### A. Caller RBAC (who runs the script)

| Role                              | Scope       | Required for                                    |
|-----------------------------------|-------------|-------------------------------------------------|
| `Contributor`                     | Foundry account | PUT/DELETE on capabilityHosts at both scopes |
| `Reader`                          | Resource group | Discover existing connections + capHosts     |
| `User Access Administrator` *or* `Owner` | Cosmos / AI Search / Storage | Granting the project MI the data-plane roles below (only needed when `--grant-rbac` is passed) |

Note: `Cognitive Services Contributor` is NOT sufficient — the
capabilityHosts subresource is gated by account-level `Contributor`.
This is the same gating as account `connections` (verified during TD-32).

The `preflight-roles.sh add-capability-host` check enforces this before
the script runs. If you don't have `Contributor` on the account, the
preflight emits a runbook describing what to ask your account owner for.

### B. Required project-MI data-plane RBAC (load-bearing)

**This is the single most common reason `/add-capability-host` fails.**

The project capabilityHost provisioner uses the project's SystemAssigned
managed identity (NOT the caller's identity) to bootstrap data structures
on the bound backing resources: containers in Cosmos, indexes in AI
Search, and a blob container in Storage. If the project MI lacks even one
of the 6 roles below, the platform retries silently for ~3 minutes and
then surfaces `provisioningState=Failed`. Recovery is destructive (DELETE
the failed host and PUT a new one) AND is blocked once any agent is
linked to the failed host, so prevention is the only viable strategy.

This was verified empirically in test (eastus2, June 2026): a freshly
bootstrapped project with all 3 connections wired but no project-MI
grants reached `Failed` in <3min; granting the 6 roles and waiting for
RBAC propagation is the only thing that flips a re-PUT to `Succeeded`.

The 6 required grants:

| # | Role                                    | Plane         | Scope                      | CLI command surface                                       |
|---|-----------------------------------------|---------------|----------------------------|-----------------------------------------------------------|
| 1 | `Cosmos DB Operator`                    | Control       | Cosmos account ARM scope   | `az role assignment create`                               |
| 2 | `Cosmos DB Built-in Data Contributor`   | **Data**      | Cosmos account, scope `/`  | `az cosmosdb sql role assignment create` (SEPARATE CLI)   |
| 3 | `Search Service Contributor`            | Control       | Search service ARM scope   | `az role assignment create`                               |
| 4 | `Search Index Data Contributor`         | Data          | Search service ARM scope   | `az role assignment create`                               |
| 5 | `Storage Account Contributor`           | Control       | Storage account ARM scope  | `az role assignment create`                               |
| 6 | `Storage Blob Data Owner`               | Data          | Storage account ARM scope  | `az role assignment create`                               |

**Gotcha:** the Cosmos data-plane role (#2) is **not** an ARM role
assignment. It lives on the Cosmos account itself as a SQL role
assignment. `az role assignment list` will not show it; use
`az cosmosdb sql role assignment list --account-name <name> --resource-group <rg>`.

Canonical CLI for a manual grant (matches what `--grant-rbac` does):

```bash
PROJ_MI=$(az rest --method get \
  --url "https://management.azure.com/${PROJ_ID}?api-version=2026-03-01" \
  | jq -r .identity.principalId)
COSMOS_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.DocumentDB/databaseAccounts/<cosmos>"
SEARCH_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Search/searchServices/<search>"
STORAGE_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Storage/storageAccounts/<storage>"

# 1, 3, 4, 5, 6 — regular ARM role assignments
az role assignment create --assignee-object-id "$PROJ_MI" --assignee-principal-type ServicePrincipal \
  --role "Cosmos DB Operator"            --scope "$COSMOS_ID"
az role assignment create --assignee-object-id "$PROJ_MI" --assignee-principal-type ServicePrincipal \
  --role "Search Service Contributor"    --scope "$SEARCH_ID"
az role assignment create --assignee-object-id "$PROJ_MI" --assignee-principal-type ServicePrincipal \
  --role "Search Index Data Contributor" --scope "$SEARCH_ID"
az role assignment create --assignee-object-id "$PROJ_MI" --assignee-principal-type ServicePrincipal \
  --role "Storage Account Contributor"   --scope "$STORAGE_ID"
az role assignment create --assignee-object-id "$PROJ_MI" --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Owner"       --scope "$STORAGE_ID"

# 2 — Cosmos data-plane (different CLI surface)
az cosmosdb sql role assignment create \
  --account-name <cosmos> --resource-group "$RG" \
  --scope "/" --principal-id "$PROJ_MI" \
  --role-definition-id 00000000-0000-0000-0000-000000000002
```

The script's `--grant-rbac` mode does exactly this set of 6 calls,
idempotently (treats `RoleAssignmentExists` as success), and then sleeps
30 seconds for AAD propagation before issuing the capabilityHost PUT.

## Verification GETs

After the script reports success, the prompt re-runs `/assess-project` against
the same project. The expected outcome is the capabilityHost verdict
flips from ⚠ to ✅:

```text
✅ Capability hosts | Project capHost 'project-capability-host' fully wired (thread + vector + storage)
```

Manual verification (the script does this automatically):

```bash
# Account-level
az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG\
/providers/Microsoft.CognitiveServices/accounts/$ACCT\
/capabilityHosts/account-capability-host?api-version=2026-03-01" \
  --query "properties.{kind:capabilityHostKind, state:provisioningState}"

# Project-level
az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG\
/providers/Microsoft.CognitiveServices/accounts/$ACCT\
/projects/$PROJ/capabilityHosts/project-capability-host?api-version=2026-03-01" \
  --query "properties.{kind:capabilityHostKind, state:provisioningState,
                       thread:threadStorageConnections,
                       vector:vectorStoreConnections,
                       storage:storageConnections}"
```

Both should report `state: Succeeded`. The project-level should list the
three connection names exactly as bound.

## Common failure modes

| Symptom                                  | Cause                                          | Fix |
|------------------------------------------|------------------------------------------------|------|
| `409 Conflict` on project PUT            | Account-level host missing or `provisioningState != Succeeded` | Re-run with `--scope account` first, or wait for account host to finish provisioning |
| `409 Conflict` on either PUT             | Host with same name already exists             | Re-run with `--force-recreate` and explicit consent, or delete via portal |
| PUT succeeds, runtime falls back to default | One of the bound connections has empty `metadata.ResourceId` | Recreate the offending connection via portal; re-run with `--force-recreate` to rebind |
| `403 Forbidden` on PUT                   | Caller lacks `Contributor` on Foundry account  | Run `/configure-rbac` or ask account owner |
| Project capHost reaches `provisioningState=Failed` within ~3min, no diagnostic detail | Project MI lacks one or more of the 6 data-plane roles from `Required project-MI data-plane RBAC` above | **Recovery is destructive AND blocked once an agent is linked.** Re-PUT with `--grant-rbac --force-recreate` BEFORE any agent is created against the failed host. Once an agent exists, the only fix is deleting the project and starting over. |
| Script exits `6` during `--grant-rbac`   | Caller lacks `User Access Administrator` / `Owner` on Cosmos / Search / Storage | Re-run after caller is granted UAA/Owner on the failing scope, OR drop `--grant-rbac` and have a privileged user run the 6 grants manually using the canonical CLI in `Required project-MI data-plane RBAC` |
| Polling never reaches `Succeeded`        | Backing resource (Cosmos / AI Search / Storage) unreachable from Foundry account's effective network | Check `networkInjections` + firewall on backing resource — likely a managed VNet / public-access mismatch |

## See also

- `/add-capability-host` prompt — interactive wrapper that calls the script
  with dry-run by default, surfaces the PUT body, and requires explicit
  consent before mutating.
- `scripts/add-capability-host.sh` — the mutator. Run directly only for
  CI/scripted scenarios.
- `scripts/discover-project-topology.sh` — emits the `CAPHOST_ACCOUNT_*` /
  `CAPHOST_PROJECT_*` / `CONNECTION_<n>_RESOURCE_ID` signals this doc relies on.
- `instructions/foundry-conventions.md` (§ Bicep) — the `ENABLE_CAPABILITY_HOST=false`
  azd default is documented there; this doc is the path beyond it.
- [Microsoft Foundry capability hosts (REST API reference)](https://learn.microsoft.com/azure/ai-foundry/agents/concepts/capability-hosts)
