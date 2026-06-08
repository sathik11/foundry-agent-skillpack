# Role × Action × Scope Matrix

Single source of truth. Every script in this package declares which row it needs and calls [scripts/preflight-role.sh](scripts/preflight-role.sh) before executing.

## How to read this

- **Action** — what the skillpack is about to do.
- **Required role** — the Azure / Entra / Foundry role that grants the operation.
- **Scope** — where the role must be assigned. `account` = Foundry AI Services account, `project` = Foundry project, `resource` = the specific data/tool resource.
- **Persona hint** — typical owner if the caller doesn't have it. Used by [runbook-emit.sh](scripts/runbook-emit.sh).

> Validity date: 2026-06-08. Re-verify against [Microsoft Learn](https://learn.microsoft.com/azure/foundry/) on a regular cadence — Foundry is preview-adjacent and roles do change.

## Rename rollout note (Microsoft Foundry RBAC, 2026)

Microsoft renamed four built-in Foundry data-plane roles. **Role definition IDs and core permissions are unchanged.** During the rollout you may see either name in the Azure portal or `az role assignment list` output depending on backend caching. Skillpack scripts that grant use the role-definition GUID; skillpack scripts that preflight are alias-aware.

| Old name | New name | Role definition ID |
|---|---|---|
| `Azure AI User` | **`Foundry User`** | `53ca6127-db72-4b80-b1b0-d745d6d5456d` |
| `Azure AI Owner` | **`Foundry Owner`** | `c883944f-8b7b-4483-af10-35834be79c4a` |
| `Azure AI Account Owner` | **`Foundry Account Owner`** | `e47c6f54-e4a2-4754-9501-8e0985b135e1` |
| `Azure AI Project Manager` | **`Foundry Project Manager`** | `eadc314b-1a2d-4efa-be10-5d325db5065e` |

Sources: [rbac-foundry](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry#built-in-roles), [quickstart-create-foundry-resources](https://learn.microsoft.com/azure/foundry/tutorials/quickstart-create-foundry-resources#for-administrators---grant-access). See [TD-30](../../../TECHNICAL_DEBT.md#td-30--foundry-rbac-role-rename--azure-ai-developer-misuse-closed-in-v0240).

> ⚠ **`Azure AI Developer` is NOT a Foundry hosted-agent role.** Per [hosted-agent permissions reference](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions): *"the Azure AI Developer built-in role is insufficient for Hosted agent scenarios. This role is scoped to Azure Machine Learning and Foundry hubs, not to the Foundry project resources used by Hosted agents."* Use `Foundry User` (data-plane minimum) or `Foundry Project Manager` (data-plane + project config writes) instead.

## Phase 0 — Preflight (Reader floor)

| Action | Required role | Scope | Persona hint |
|---|---|---|---|
| Read Foundry account / project metadata | `Reader` | account | Caller |
| Read source resource for network preflight (AI Search, Storage, Cosmos, Fabric capacity) | `Reader` | each declared resource | Caller |
| Read Application Insights schema for KQL queries | `Reader` | App Insights resource | Caller |
| List ACR repositories | `Reader` + `AcrPull` | ACR | Caller |

If `Reader` is missing on a resource, the skillpack **does not stop** — it degrades the affected gate to a checklist and prints the runbook.

## Phase 1 — Build & deploy

| Action | Required role | Scope | Persona hint |
|---|---|---|---|
| `azd up` (create agent version + Entra agent identity) | `Contributor` | Foundry account RG | DevOps |
| Push image to ACR (BYO build, not ACR Tasks) | `AcrPush` or `Container Registry Repository Writer` | ACR | DevOps |
| Pull image from ACR (Project MI; auto-assigned by azd) | `AcrPull` or `Container Registry Repository Reader` | ACR | Verify only — azd assigns |
| Create / edit Foundry connections (MCP, AI Search, etc.) | `Foundry Project Manager` | project | DevOps |
| Set environment variables on a version | `Foundry Project Manager` | project | DevOps |
| Create model deployment (`POST .../deployments/<name>`) | `Cognitive Services Contributor` | account | DevOps — runbook if caller lacks it (see [model-selection.md](../foundry-deploy/model-selection.md) Step 2.4 fork (b)) |

## Phase 2 — Per-agent identity grants

These run **after** `azd up` (the per-agent SP doesn't exist before that). The caller granting them needs `Owner` or `User Access Administrator` at the relevant scope.

| Grant target → role | Scope | Persona hint |
|---|---|---|
| Per-agent SP → `Foundry User` | account (critical) + project | DevOps |
| Per-agent SP → `Cognitive Services OpenAI User` | account | DevOps |
| Per-agent SP → `Cognitive Services User` | account | DevOps |
| Per-agent SP → `Cognitive Services User` (when guardrails use CS) | Content Safety resource | DevOps |
| Per-agent SP → `Search Index Data Reader` | AI Search resource | DevOps |
| Per-agent SP → `Storage Blob Data Reader` | Storage account | DevOps |
| Per-agent SP → `Cosmos DB Built-in Data Contributor` (`00000000-0000-0000-0000-000000000002`) | Cosmos account | DevOps |

## Phase 3 — Evaluation, monitoring, red-team

| Action | Required role | Scope | Persona hint |
|---|---|---|---|
| Create / update continuous evaluation rule | `Foundry User` | project | DevOps |
| Create / update scheduled evaluation (preview) | `Foundry User` | project | DevOps |
| Create / schedule cloud red-team (preview) | `Foundry User` | project | DevOps |
| Configure Monitor dashboard alerts (preview, portal-only today) | `Foundry User` + `Monitoring Contributor` | project + App Insights RG | DevOps |
| Read continuous-eval results from App Insights | `Reader` + `Log Analytics Reader` | App Insights + Log Analytics | Caller |

## Phase 4 — Network isolation (managed VNet / BYO VNet)

| Action | Required role | Scope | Persona hint |
|---|---|---|---|
| Create managed VNet on Foundry account | `Contributor` | Foundry account | DevOps |
| Approve managed private endpoint connection (Foundry → resource) | `Azure AI Enterprise Network Connection Approver` (`b556d68e-0be0-4f35-a333-ad7ee1ce17ea`) | Foundry account MI assigned on target resource | DevOps |
| Approve PE on the target resource (when role above isn't pre-granted) | `Contributor` or `Owner` | target resource | Resource owner — runbook |
| Create delegated subnet for BYO VNet injection (`Microsoft.App/environments`, /27+) | `Network Contributor` | VNet + subnet | Network admin — runbook |
| Link private DNS zone to VNet | `Network Contributor` | private DNS zone + VNet | Network admin — runbook |
| Update NSG / Firewall rules | `Network Contributor` | NSG / Firewall | Network admin — runbook |

## Phase 5 — Tenant-scoped (almost always runbook)

| Action | Required role | Scope | Persona hint |
|---|---|---|---|
| Toggle Microsoft Purview integration on Foundry account | `Cognitive Services Security Integration Administrator` or `Foundry Account Owner` | account | Tenant admin — runbook |
| Create DSPM / DLP policies for AI | `Purview Data Security AI Admin` | tenant | Tenant admin — runbook |
| Add per-agent identity to Fabric workspace | `Fabric Admin` (workspace) | Fabric workspace | Fabric admin — runbook (TD-1) |
| Register agent in Agent 365 / Teams | `Teams Administrator` + `M365 Admin` | tenant | M365 admin — runbook |
| Create Entra app (when Conditional Access blocks self-service) | `Application Administrator` | tenant | Tenant admin — runbook |

## Action → script lookup

For tooling — `preflight-role.sh` accepts an action name as a synonym for the (role, scope) pair:

| Action keyword | Resolves to |
|---|---|
| `plan-agent` | Phase 0, `Reader` on RG + ability to list a Foundry account in that RG (used by `/plan-agent` Step 0a) |
| `prepare-deploy` | Phase 1, `Contributor` on account RG + `Foundry Project Manager` on project (used by `/prepare-deploy` Step 0). `Foundry User` alone is insufficient because `azd up` writes env vars on the agent version — a project-config write that needs Project Manager. |
| `deploy` | Phase 1, `Contributor` on account RG |
| `model-deploy` | Phase 1, `Cognitive Services Contributor` on account (gates `/prepare-deploy` Step 2.4 fork (b) — deploy missing model with consent) |
| `grant-rbac` | Phase 2, `Owner` or `User Access Administrator` on grant target |
| `setup-evals` | Phase 3, `Foundry User` on project |
| `setup-redteam` | Phase 3, `Foundry User` on project + region check (East US 2 / France Central / Sweden Central / Switzerland West / North Central US) |
| `network-preflight` | Phase 0, `Reader` on each declared resource |
| `audit-drift` | Phase 0, `Reader` on the project + each declared resource (read-only reconciler; never mutates) |
| `approve-pe` | Phase 4, `Azure AI Enterprise Network Connection Approver` on target |
| `purview-toggle` | Phase 5, `Cognitive Services Security Integration Administrator` on account |
| `fabric-workspace-add` | Phase 5, Fabric `Admin` on workspace |

## Notes

- **Why not collapse to one mega-role per persona?** Tempting but wrong. `Owner` on a project doesn't grant tenant-scoped Purview operations or Fabric workspace admin. Persona is a hint; scope is the truth.
- **Why not fold this into `foundry-identity`?** `foundry-identity` covers the *agent's* identities (project MI + per-agent SP). This skill covers the *caller's* identity. Different actor, same conceptual surface — but mixing them led to confusion in earlier drafts.
- **Re-evaluate cadence.** Foundry GA waves and preview promotions change role names (e.g. `Foundry User` was once `AzureML Data Scientist`, then `Azure AI User`, now `Foundry User`). When the daily docs scan flags a role rename, update the rename rollout table above first, then propagate.
