<!-- MAINTAINER/CI-ONLY (W5-T3). The roles the E2E test service principal needs.
     YOU create the SP + assign these in the Azure portal (one-time, your control).
     This doc only tells you WHAT to assign and WHY. Authoritative source: the skillpack's
     own role matrix → foundry-agent-skillpack/.apm/skills/foundry-roles/role-matrix.md. -->

# E2E Test Service Principal — Required Roles

You create one **service principal** in the portal and assign the roles below. The test workflow
authenticates as that SP via repo secrets (see *Wiring the SP into GitHub* §). Nothing in this
repo creates identities or assigns roles — that stays under your control.

The SP plays the **DevOps caller** for the *entire* lifecycle the harness exercises: provision the
standing baseline → `azd up` the agent → per-agent RBAC fan-out → evals → teardown. That is the
union of Phases 1–3 in the [role matrix](../foundry-agent-skillpack/.apm/skills/foundry-roles/role-matrix.md),
plus permission to create the **role-assignment resources the bicep itself contains**.

## What the vendored bicep already auto-grants (so you don't)

`infra/core/ai/ai-project.bicep` assigns the **deploying principal** (your SP, passed as
`principalId`) the **`Foundry User`** data-plane role (`53ca6127-db72-4b80-b1b0-d745d6d5456d`) on the
Foundry account automatically. So you do **not** assign `Foundry User` by hand — but note the
template *creates a role assignment*, which is why the SP needs RBAC-write to deploy at all (below).

## Roles to assign (the minimal, control-preserving set)

Scope everything to the **dedicated E2E resource group** unless noted. Two equivalent options:

### Option A — simplest (recommended): `Owner` on the dedicated RG
| Role | Scope | Why |
|---|---|---|
| **Owner** | dedicated E2E RG | Subsumes Contributor (provision baseline, `azd up`, ACR push, networking, model deployment) **and** role-assignment write (the bicep + Phase-2 per-agent grants both create `Microsoft.Authorization/roleAssignments`). |
| **Foundry Project Manager** | E2E RG (cascades to the project) | `azd up` writes **environment variables on the agent version** — a project-config write that `Foundry User` (auto-granted) does **not** cover. Matrix Phase 1. |
| **Cognitive Services OpenAI User** | **driver-model RG** (cross-RG) | The test *driver brain* (your GPT-5.4 deployment in a separate RG, W3) — lets the SP call that model. Not in the E2E RG. |

### Option B — least-privilege (more roles, no `Owner`)
Use this if org policy forbids `Owner` for automation:
| Role | Scope | Replaces |
|---|---|---|
| **Contributor** | E2E RG | control-plane provisioning + `azd up` + model deployment + ACR push |
| **Role Based Access Control Administrator** | E2E RG | creating the bicep's role assignments + Phase-2 per-agent grants (more constrained than User Access Administrator; can't grant Owner) |
| **Foundry Project Manager** | E2E RG | project-config writes (env vars on version) |
| **Cognitive Services OpenAI User** | driver-model RG | driver brain access |

> `Azure AI Developer` is **NOT** sufficient for hosted agents (MS Learn) — do not use it. See the
> matrix's rename note: `Foundry User`/`Foundry Project Manager` are the current names (role-def IDs
> unchanged through the 2026 rename).

## The one subscription-scope decision (deployment scope)

`infra/main.bicep` is **subscription-scoped** and *creates the RG itself* (`az deployment sub create`).
That means the SP needs a role at **subscription** scope just to run the deployment — broader than RG
isolation. Two ways to keep blast radius at the RG:

1. **Pre-create the RG yourself** (you want control anyway), then we deploy **RG-scoped**. Ask me to
   add the group-scoped entry (`baseline.sh DEPLOY_SCOPE=group`) and you only ever grant at RG scope.
   **Recommended.**
2. **Accept a subscription-scoped grant** (Owner/Contributor+RBAC-Admin at the subscription) and let
   the deployment create the RG. Simplest to run, broadest permission.

Until you decide, `baseline.sh provision` uses option 2 (sub-scoped). Tell me to wire option 1 and
I'll add the RG-scoped template path.

## Verify (read-only) after you assign

```bash
SP_APPID=<your sp appId>
SP_OID=$(az ad sp show --id "$SP_APPID" --query id -o tsv)
# RG-scoped roles
az role assignment list --assignee "$SP_OID" \
  --scope /subscriptions/<sub>/resourceGroups/<e2e-rg> -o table
# cross-RG driver model
az role assignment list --assignee "$SP_OID" \
  --scope /subscriptions/<sub>/resourceGroups/<driver-model-rg> -o table
```
Expect (Option A): `Owner`, `Foundry Project Manager` on the E2E RG; `Cognitive Services OpenAI User`
on the driver-model RG.

## Wiring the SP into GitHub (you choose the auth style)

The workflows call `azure/login`. Two supported styles — pick one:

- **SP secret (simplest, what you described):** create a client secret on the SP, store it as the
  repo secret **`AZURE_CREDENTIALS`** (the JSON `az ad sp create-for-rbac --sdk-auth` emits, or hand-
  built `{clientId,clientSecret,tenantId,subscriptionId}`). The workflow uses `creds: ${{ secrets.AZURE_CREDENTIALS }}`.
- **OIDC (no stored secret):** add a federated credential on the SP for this repo + the `e2e` /
  `production-pins` environments, and set secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`,
  `AZURE_SUBSCRIPTION_ID`. More secure; slightly more portal setup.

Both are supported by the workflow's login step (it prefers `AZURE_CREDENTIALS` if present, else
falls back to OIDC client-id). The watcher/E2E jobs **auto-skip** the Azure-dependent steps until
one of these is configured, so nothing breaks before you set it up.

## Cross-reference

Authoritative, kept-current role matrix (per action × scope, all 5 phases incl. network + Purview):
[`foundry-roles/role-matrix.md`](../foundry-agent-skillpack/.apm/skills/foundry-roles/role-matrix.md).
