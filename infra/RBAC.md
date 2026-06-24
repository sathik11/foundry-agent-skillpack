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

## Roles to assign (headless-safe, RG-scoped)

You pre-created the dedicated RG and we deploy **RG-scoped** (`baseline.sh DEPLOY_SCOPE=group`,
which is the default), so **every grant below is at the RG — nothing at subscription scope.**

**A headless service principal should NOT be `Owner`.** `Owner` can grant any role (including
`Owner`/`User Access Administrator`) — an escalation surface you don't want on an unattended
credential. Use this least-privilege set instead:

| Role | Scope | Why |
|---|---|---|
| **Contributor** | dedicated E2E RG | provision the baseline, `azd up`, model deployment, ACR push, networking |
| **Role Based Access Control Administrator** | dedicated E2E RG | create the role-assignments the bicep contains + the Phase-2 per-agent grants. **Safer than Owner/UAA for headless:** it cannot grant `Owner` and supports a constraining condition. |
| **Foundry Project Manager** | dedicated E2E RG (cascades to the project) | `azd up` writes **environment variables on the agent version** — a project-config write `Foundry User` (auto-granted by the bicep) does not cover |
| **Cognitive Services OpenAI User** | **driver-model RG** (cross-RG) | lets the SP call your GPT-5.4 driver brain (separate RG, W3) |

> Optionally scope the **RBAC Administrator** assignment with a condition that restricts which
> role-definition IDs it may grant (to exactly the Phase-2 set: `Foundry User`, `Cognitive Services
> OpenAI User`, `Cognitive Services User`, `Search Index Data Reader`, `Storage Blob Data Reader`,
> `Cosmos DB Built-in Data Contributor`). Tightest posture; optional.

`Azure AI Developer` is **NOT** sufficient for hosted agents (MS Learn). Current role names are
`Foundry User` / `Foundry Project Manager` (role-def IDs unchanged through the 2026 rename).

## Deployment scope — resolved

You pre-created the RG, so we use **RG-scoped deployment** (`main-group.bicep`, the RG-scoped sibling
of `main.bicep`). `baseline.sh` defaults to `DEPLOY_SCOPE=group` and **fails fast** if the RG is
missing. The SP therefore needs **no subscription-scoped role**. (`DEPLOY_SCOPE=sub` + `main.bicep`
remains available for the create-the-RG-too path, which would require a subscription grant.)

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
Expect: `Contributor`, `Role Based Access Control Administrator`, `Foundry Project Manager` on the
E2E RG; `Cognitive Services OpenAI User` on the driver-model RG.

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
