---
description: Wire BYO Cosmos / AI Search / Storage to a Foundry project's capabilityHost — interactive dry-run-by-default prompt that calls add-capability-host.sh after explicit consent
input:
  - subscription_id: "Subscription ID (e.g. 00000000-0000-0000-0000-000000000000). Required."
  - resource_group: "Resource group containing the Foundry account. Required."
  - account_name: "Foundry account name. Required."
  - project_name: "Project name within the account. Required."
  - thread_connection: "Cosmos DB connection name (category=CosmosDb). Optional — auto-picked if exactly one exists; picklist surfaced if multiple."
  - vector_connection: "AI Search connection name (category=CognitiveSearch). Optional — same auto-pick rule."
  - storage_connection: "Storage connection name (category=AzureStorageAccount). Optional — same auto-pick rule."
  - aiservices_connection: "AI Services connection name. Optional — usually auto-resolved by the project."
  - thread_resource_id: "ARM ID of an EXISTING Microsoft.DocumentDB/databaseAccounts to wire as a new threadStorage connection. Optional — only used when no Cosmos connection exists yet."
  - vector_resource_id: "ARM ID of an EXISTING Microsoft.Search/searchServices to wire as a new vectorStore connection. Optional — only used when no AI Search connection exists yet."
  - storage_resource_id: "ARM ID of an EXISTING Microsoft.Storage/storageAccounts to wire as a new storage connection. Optional — only used when no Storage connection exists yet."
  - scope: "account|project|both. Default 'both'. Use 'project' when the account-level capHost already exists."
  - force_recreate: "true|false — if a same-name capabilityHost already exists, DELETE and recreate. Default false. Requires explicit user consent in Step 5."
  - grant_rbac: "true|false — grant the project's SystemAssigned MI the 6 control-plane + data-plane roles capabilityHost provisioning REQUIRES on the bound Cosmos / AI Search / Storage. Default false (we don't auto-grant), but the prompt STRONGLY recommends setting true unless the user explicitly confirms RBAC is already in place. Empirically: without these grants the project capabilityHost reaches provisioningState=Failed within ~3min. See capability-host-bootstrap.md → 'Required project-MI data-plane RBAC'."
  - assessment_dir: "Where /assess-project wrote project-topology.json. Default './assessment'."
---

# Add capability host (BYO Cosmos + AI Search + Storage)

You are a Foundry Agent Engineer wiring a project's bring-your-own
capability host. This prompt is the **only supported skillpack path** for
that mutation. Read [`capability-host-bootstrap.md`](../skills/foundry-deploy/capability-host-bootstrap.md)
before invoking — it covers the REST contract, two-scope ordering rule,
connection prerequisites, and idempotency contract.

> **Mutation contract.** This prompt WILL `PUT` and (with explicit
> consent) `DELETE` `Microsoft.CognitiveServices/.../capabilityHosts`
> resources. It is **dry-run by default** — the underlying script never
> mutates without the explicit `--no-dry-run` flag, which this prompt
> only passes after a recorded user `yes` in Step 5.

## When this prompt is the right call

`/assess-project` flagged the `Capability hosts` verdict as ⚠ — one of:

- No capability host at any scope → agents fall back to Microsoft-managed default state.
- Account-level host exists but project-level missing → Agent Service is enabled at the account, but no BYO connections are active for the project.
- Project-level host exists but bindings partial (missing thread / vector / storage) → silent fallback to default storage at runtime.

This prompt is **not** for the initial deploy of Cosmos / AI Search / Storage resources themselves. The Foundry connections that point at them either (a) already exist (the common path — Foundry portal usually creates them on first project bootstrap) or (b) can be created inline by this prompt from an EXISTING Azure resource's ARM ID via the `thread_resource_id` / `vector_resource_id` / `storage_resource_id` inputs. See the `Required connections` section of `capability-host-bootstrap.md` for the connection contract.

## Step 0 — Caller-role preflight

The mutation needs `Contributor` on the Foundry account. Run:

```bash
.agents/skills/foundry-roles/scripts/preflight-roles.sh add-capability-host \
  ${input:subscription_id} ${input:resource_group} \
  ${input:account_name} ${input:project_name}
```

If preflight reports a missing role, STOP and surface the runbook the script emits. Do not proceed — the PUT will return `403 Forbidden` clearly enough, but failing early avoids burning the user's time.

## Step 1 — Cached topology pickup

The `/assess-project` run that recommended this prompt has already written
`project-topology.json`. Read it to confirm what's currently in place:

```bash
ASSESS_DIR="${input:assessment_dir:-./assessment}"
if [[ -f "$ASSESS_DIR/project-topology.json" ]]; then
  jq -r '
    "Current state:",
    "  Project capHost count: \(.raw.CAPHOST_PROJECT_COUNT // "0")",
    "  Account capHost count: \(.raw.CAPHOST_ACCOUNT_COUNT // "0")",
    (.verdicts[] | select(.category == "Capability hosts") | "  Verdict: \(.symbol) \(.headline)")
  ' "$ASSESS_DIR/project-topology.json"
else
  echo "[!] No cached assessment at $ASSESS_DIR/project-topology.json. Run /assess-project first." >&2
  echo "    (You can continue without it, but the script will re-probe everything itself.)" >&2
fi
```

If the cached JSON shows the project capHost is already fully wired (verdict
`✅`), STOP and tell the user — there is nothing to do. Re-running this
prompt would either no-op (default) or destructively recreate (with
`force_recreate`).

## Step 2 — Confirm scope and connections with the user

If the cached state shows:

- **Both hosts missing** → recommend `scope=both` (default).
- **Account host present, project host missing** → recommend `scope=project`.
- **Both present, bindings partial** → this requires `force_recreate=true` (delete + recreate); explicit consent in Step 5.

If `thread_connection` / `vector_connection` / `storage_connection` were not provided as inputs, parse `project-topology.json` to list candidates by category and ask the user. Categories to grep:

| Role | Category in connections list |
|---|---|
| `threadStorage` | `CosmosDb` |
| `vectorStore` | `CognitiveSearch` |
| `storage` | `AzureStorageAccount` |

If exactly one connection exists per category, surface it and ask the user to confirm (e.g. *"I'll bind threadStorage to `agents-3iq-ncus-2-cosmosdb` — OK?"*). If multiple, present a numbered picklist and wait for the user's pick. **Do NOT silently default to the first** — same reasoning as the `/assess-project` exit-4 dispatch.

**If zero connections of a category exist**, ask the user:

> No `<Cosmos|CognitiveSearch|AzureStorageAccount>` connection exists on this project. You have two options:
>
> 1. **Create the connection in the Foundry portal first** (Settings → Connected resources → +Add), then re-run this prompt.
> 2. **Provide an ARM ID of an existing Azure resource** and I'll create the Foundry connection inline before wiring the capability host. Required provider:
>    - threadStorage → `Microsoft.DocumentDB/databaseAccounts`
>    - vectorStore → `Microsoft.Search/searchServices`
>    - storage → `Microsoft.Storage/storageAccounts`
>
> Paste an ARM ID, or type `portal` to abort and use option 1.

If the user picks option 2, capture the ARM ID into the matching input (`thread_resource_id` / `vector_resource_id` / `storage_resource_id`) and pass it to the script in Step 3 via `--thread-resource-id` / `--vector-resource-id` / `--storage-resource-id`. The script validates the provider segment and aborts if it doesn't match the expected role.

## Step 2.5 — Confirm RBAC posture (load-bearing)

The project capabilityHost provisioner uses the project's **SystemAssigned managed identity** to bootstrap containers in the bound Cosmos account, indexes in the bound Search service, and blobs in the bound Storage account. If the project MI lacks those data-plane roles, the platform retries silently for ~3 minutes and then fails with `provisioningState=Failed` — and once an agent is linked to that failed host, the host can't be DELETEd, so recovery requires deleting the project (verified empirically in test).

The 6 roles (see [`capability-host-bootstrap.md` → Required project-MI data-plane RBAC](../skills/foundry-deploy/capability-host-bootstrap.md) for canonical CLI):

| Backing | Control plane | Data plane |
|---|---|---|
| Cosmos  | Cosmos DB Operator | Cosmos DB Built-in Data Contributor (granted via `az cosmosdb sql role assignment create`, NOT regular RBAC) |
| Search  | Search Service Contributor | Search Index Data Contributor |
| Storage | Storage Account Contributor | Storage Blob Data Owner |

Ask the user:

> Has the project's managed identity already been granted the 6 data-plane roles on the backing Cosmos / AI Search / Storage resources?
>
> - Type `grant` (recommended) to have me grant them as part of this run (idempotent — safe to re-run).
> - Type `already granted` if you've verified all 6 are in place (e.g. via Bicep/Terraform).
> - Type `skip` only if you understand the project capHost may fail to provision (e.g. you are testing the failure mode).

Set `grant_rbac=true` for `grant`, leave `grant_rbac=false` for `already granted`, and STOP if the user types `skip` without acknowledging the consequence in the same turn.

## Step 3 — Dry-run preview (always first, no exceptions)

```bash
.agents/skills/foundry-deploy/scripts/add-capability-host.sh \
  ${input:subscription_id} \
  ${input:resource_group} \
  ${input:account_name} \
  ${input:project_name} \
  --scope ${input:scope:-both} \
  $( [[ -n "${THREAD_CONN:-}" ]] && echo "--thread-conn $THREAD_CONN" ) \
  $( [[ -n "${VECTOR_CONN:-}" ]] && echo "--vector-conn $VECTOR_CONN" ) \
  $( [[ -n "${STORAGE_CONN:-}" ]] && echo "--storage-conn $STORAGE_CONN" ) \
  $( [[ -n "${AISERVICES_CONN:-}" ]] && echo "--aiservices-conn $AISERVICES_CONN" ) \
  $( [[ -n "${input:thread_resource_id:-}" ]] && echo "--thread-resource-id ${input:thread_resource_id}" ) \
  $( [[ -n "${input:vector_resource_id:-}" ]] && echo "--vector-resource-id ${input:vector_resource_id}" ) \
  $( [[ -n "${input:storage_resource_id:-}" ]] && echo "--storage-resource-id ${input:storage_resource_id}" ) \
  $( [[ "${input:force_recreate:-false}" == "true" ]] && echo "--force-recreate" ) \
  $( [[ "${input:grant_rbac:-false}" == "true" ]] && echo "--grant-rbac" ) \
  2>&1 | tee /tmp/add-capability-host.dryrun.log
EXIT=$?
echo "[i] dry-run exit code: $EXIT"
```

The script will:

1. For each role, resolve a binding via this priority: (a) use the existing connection name if `--<role>-conn` matches one, (b) PLAN INLINE CREATE if `--<role>-resource-id` is provided, (c) auto-pick if exactly one connection of the category exists, (d) exit `2` if multiple candidates and no `--<role>-conn` given, (e) exit `1` if zero candidates and no `--<role>-resource-id` given.
2. Verify `metadata.ResourceId` is populated on every chosen EXISTING connection (exits `3` if any is empty). Inline-create plans are exempt from this check — the script populates `ResourceId` itself from the supplied ARM ID.
3. Detect existing capabilityHosts at each scope (exits `4` if a target name is already taken and `--force-recreate` was not passed).
4. Print the planned-operations summary (including any `project connections to CREATE`) followed by the exact PUT bodies it WOULD issue (connection creates first, then account-level + project-level capHosts) and exit `5` to indicate dry-run complete.

| Exit | What it means | What to do |
|---|---|---|
| `5` | Dry-run complete | Show the PUT bodies and the planned-operations summary to the user. Continue to Step 4. |
| `1` | A role has zero connections AND no `--<role>-resource-id` was provided | Re-engage user with the two-option prompt from Step 2 (portal create vs. paste ARM ID). |
| `2` | Ambiguous connection — multiple of one category but no `--<role>-conn` given | Surface the `PICKLIST_<ROLE>_<n>=` keys, ask the user to pick, re-run Step 3. |
| `3` | Chosen EXISTING connection has empty `metadata.ResourceId` | STOP. Tell the user to recreate the connection via the portal (the portal flow always populates `ResourceId`). See [`capability-host-bootstrap.md` → Required connections](../skills/foundry-deploy/capability-host-bootstrap.md). |
| `4` | Same-name capabilityHost already exists | Ask the user whether to re-run with `force_recreate=true` (destructive — see Step 5). |
| `6` | RBAC grant failed (caller lacks `Microsoft.Authorization/roleAssignments/write` on the backing resources, or Cosmos data-plane grant failed) | STOP. Show the user which role/scope failed. Either re-run after the caller is granted Owner / User Access Administrator on the failing scope, OR drop `--grant-rbac` and have a privileged user grant the 6 roles manually (see `capability-host-bootstrap.md`). |
| `0` | Should not happen in dry-run | Surface the log and STOP. |
| other | Script-internal error (e.g. ARM provider mismatch) | Tail `/tmp/add-capability-host.dryrun.log` and surface. |

## Step 4 — Show the user what will happen

Render to the user:

> About to wire capability host on project **`${input:project_name}`**:
>
> - Project connections to CREATE (inline from BYO ARM IDs): `N`
>   - `<conn-name>` (category=`<CosmosDb|CognitiveSearch|AzureStorageAccount>`) → `<arm-id>`
>   - …
> - Account-level host: `<account-capability-host>` (will **CREATE** | will **SKIP** — already exists | will **DELETE+RECREATE**)
> - Project-level host: `<project-capability-host>` (will **CREATE** | will **DELETE+RECREATE**)
>   - threadStorage → `<conn-name>` (Cosmos)
>   - vectorStore → `<conn-name>` (AI Search)
>   - storage → `<conn-name>` (Storage)
>   - aiServices → `<conn-name>` (optional)
> - RBAC grants (only if `grant_rbac=true`): **6** roles to project MI on the backing resources
>   - Cosmos DB Operator + Cosmos DB Built-in Data Contributor → `<cosmos-arm-id>`
>   - Search Service Contributor + Search Index Data Contributor → `<search-arm-id>`
>   - Storage Account Contributor + Storage Blob Data Owner → `<storage-arm-id>`
>
> The PUT bodies are above. Re-applying is destructive — there is no in-place UPDATE on capabilityHosts.

## Step 5 — Explicit consent

Ask, verbatim:

> Apply this? Type `yes` to mutate, or anything else to abort.

**Do NOT proceed without a literal `yes`** (case-insensitive). If the planned operation includes any DELETE (i.e. `WILL_DELETE_ACCT=true` or `WILL_DELETE_PROJ=true` from the dry-run output), additionally ask:

> This will DELETE the existing capability host(s) before recreating. Existing thread history / vector indexes / file blobs in the bound connections are NOT touched, but any agent runs in flight during the delete window will fail with 5xx. Continue? Type `yes confirm delete`.

Only the literal `yes confirm delete` (case-insensitive) proceeds with deletion paths.

## Step 6 — Apply

```bash
.agents/skills/foundry-deploy/scripts/add-capability-host.sh \
  ${input:subscription_id} \
  ${input:resource_group} \
  ${input:account_name} \
  ${input:project_name} \
  --scope ${input:scope:-both} \
  $( [[ -n "${THREAD_CONN:-}" ]] && echo "--thread-conn $THREAD_CONN" ) \
  $( [[ -n "${VECTOR_CONN:-}" ]] && echo "--vector-conn $VECTOR_CONN" ) \
  $( [[ -n "${STORAGE_CONN:-}" ]] && echo "--storage-conn $STORAGE_CONN" ) \
  $( [[ -n "${AISERVICES_CONN:-}" ]] && echo "--aiservices-conn $AISERVICES_CONN" ) \
  $( [[ -n "${input:thread_resource_id:-}" ]] && echo "--thread-resource-id ${input:thread_resource_id}" ) \
  $( [[ -n "${input:vector_resource_id:-}" ]] && echo "--vector-resource-id ${input:vector_resource_id}" ) \
  $( [[ -n "${input:storage_resource_id:-}" ]] && echo "--storage-resource-id ${input:storage_resource_id}" ) \
  $( [[ "${input:force_recreate:-false}" == "true" ]] && echo "--force-recreate" ) \
  $( [[ "${input:grant_rbac:-false}" == "true" ]] && echo "--grant-rbac" ) \
  --no-dry-run \
  2>&1 | tee /tmp/add-capability-host.apply.log
EXIT=$?
```

| Exit | Meaning |
|---|---|
| `0` | Both PUTs succeeded and verification GETs confirmed `provisioningState: Succeeded` |
| anything else | Tail `/tmp/add-capability-host.apply.log` and surface — partial state may exist (account host created, project host failed). Re-run `/assess-project` to see what's there. |

The script's last `[+]` line will print the verification — account host name + state, and project host name + state + bindings.

## Step 7 — Re-verify with /assess-project

```bash
.agents/skills/foundry-deploy/scripts/assess-project.sh \
  ${input:subscription_id} ${input:resource_group} \
  ${input:account_name} ${input:project_name} \
  "${input:assessment_dir:-./assessment}"
```

The `Capability hosts` row should now read:

> ✅ Capability hosts | Project capHost 'project-capability-host' fully wired (thread + vector + storage) | foundry-deploy/capability-host-bootstrap.md

If it's still ⚠ after a `0` exit on Step 6, the script's verification likely caught a `ResourceId`-missing mismatch the dry-run somehow missed; re-read the assessment detail and pursue the specific gap.

## Forbidden shortcuts

- ❌ Do NOT skip the dry-run (Step 3) and jump straight to `--no-dry-run`. The dry-run is the only place the user sees the exact PUT body and the planned-operations summary.
- ❌ Do NOT silently auto-pick a connection when multiple of a category exist. Force a picklist, same as `/assess-project` exit-4 dispatch.
- ❌ Do NOT accept an ARM ID for `--<role>-resource-id` that the user did not explicitly type or paste in chat. Confirm the ARM ID back to the user before passing it to the script.
- ❌ Do NOT pass `--<role>-resource-id` when an existing connection of that category already binds the resource — re-use the existing connection instead. The script's dry-run will reveal this collision via the `connection already exists` guard.
- ❌ Do NOT pass `--force-recreate` without the literal `yes confirm delete` consent in Step 5.
- ❌ Do NOT proceed if any EXISTING connection's `metadata.ResourceId` is empty — the runtime will silently fall back to default storage. Fix the connection first.
- ❌ Do NOT attempt to create the Cosmos / AI Search / Storage **Azure resources** from this prompt — only the Foundry **connection** that points at an existing Azure resource. New Azure resources need Bicep/azd/portal.
- ❌ Do NOT skip the post-PUT GET verification on inline-created connections — Step 7a re-reads each connection and aborts before the capHost PUT if `metadata.ResourceId` came back empty.
- ❌ Do NOT assume capabilityHosts support UPDATE. The API only supports PUT (which 409s on collision) and DELETE. "Change a binding" = delete + recreate.
- ❌ Do NOT batch multiple projects in one invocation. Run the prompt once per project so each consent gate is explicit.
- ❌ Do NOT issue the capability-host PUT without verifying the 6 project-MI data-plane RBAC grants are in place. Either set `grant_rbac=true` (recommended; the script grants idempotently and sleeps 30s for propagation before the PUT) OR have the user confirm in chat that all 6 roles from [`capability-host-bootstrap.md` → Required project-MI data-plane RBAC](../skills/foundry-deploy/capability-host-bootstrap.md) are already granted. Empirically: skipping this step makes the project capHost reach `provisioningState=Failed` within ~3min, and the only recovery is DELETE+PUT (which is blocked once an agent is linked).
