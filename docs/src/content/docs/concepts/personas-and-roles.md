---
title: Personas and roles
description: How the skillpack handles the gap between developer and tenant-admin operations.
---

The skillpack assumes one human runs `/prepare-deploy`, `azd up`, `/configure-rbac`, and `/verify-agent` in sequence — the dev/devops persona collapsed into one. That's the working assumption.

But many actions the lifecycle requires are **tenant-scoped** and that one human almost never has the rights to perform them: flipping the Purview integration toggle, granting Purview Information Protection roles, adding a per-agent identity to a Fabric workspace, registering an agent in Agent 365.

When that happens, the skillpack emits a **paste-ready runbook block** for the right tenant admin instead of failing silently.

## The role matrix

Every action the skillpack performs declares its required role + scope. The full matrix is shipped as a skill: see [Role Matrix](/reference/role-matrix/).

The five phases:

| Phase | Action class | Typical persona |
| --- | --- | --- |
| 0 | Read-only preflight | Caller (Reader floor) |
| 1 | Build & deploy (`azd up`) | DevOps (`Contributor` on RG) |
| 2 | Per-agent identity grants | DevOps (`Owner` / `User Access Administrator`) |
| 3 | Eval / monitoring / red-team | DevOps (`Azure AI User` on project) |
| 4 | Network isolation operations | Network Admin |
| 5 | Tenant-scoped (Purview, Fabric, Teams, Entra) | Tenant / Compliance / Fabric / M365 admin |

## The runbook handoff

When `preflight-role.sh` detects the caller lacks a required role, instead of erroring it emits this:

```markdown
### 🔐 Action required: purview-toggle

| Field | Value |
|---|---|
| Persona | Tenant Admin |
| Required role | `Cognitive Services Security Integration Administrator` |
| Role ID | `<guid>` |
| Scope | `/subscriptions/.../accounts/<foundry-account>` |
| Granted to | `<caller object id>` |
| Why | Phase B Purview integration toggle for agent `<name>` |
| Verify with | `az role assignment list --assignee <oid> --scope ...` |

**Exact command for the assignee to run:**

```bash
az role assignment create \
  --assignee-object-id <oid> ...
```
```

The dev pastes that into ServiceNow / Slack / a PR comment. The tenant admin runs it. The dev re-runs the skillpack step after RBAC propagation.

This pattern means the dev never has to:
- Guess what role they need.
- Know the role's GUID.
- Find the right scope ARM path.
- Tell the admin what command to run.
- Forget that 5–15 min RBAC propagation is real.

## Phase 0 degradation

`Reader` is the **floor** for any preflight check. When the caller lacks Reader on a particular resource, the skillpack:

1. Logs a warning that this resource's gate is degraded.
2. Continues with other gates.
3. Reports the gap as `⚠ unknown` in the gate matrix.
4. Suggests running `list-my-roles.sh` to see what the caller does have.

We **never** stop because of a Reader gap — that pattern leads to dev frustration and people granting themselves Owner on production subscriptions to make the skillpack work.

## Why not collapse to one mega-role per persona

Tempting but wrong. `Owner` on a project doesn't grant tenant-scoped Purview operations or Fabric workspace admin. `Contributor` on an RG doesn't grant data-plane Search Index Data Reader. Persona is a hint; **scope is the truth**.

## The three caller-side scripts

| Script | What it does |
| --- | --- |
| [`preflight-role.sh`](/reference/scripts/) | Single-call: do I have role X on scope Y? Emit runbook on failure. |
| [`runbook-emit.sh`](/reference/scripts/) | Standalone runbook emitter (used by other scripts when they detect they need to escalate). |
| [`list-my-roles.sh`](/reference/scripts/) | Debug: dump every role the caller has across declared scopes. Useful before opening a new repo. |

## Read next

- [The capability manifest](/concepts/capability-manifest/) — what the user declares.
- [The lifecycle](/concepts/lifecycle/) — when each role check fires.
- [Role matrix reference](/reference/role-matrix/) — every action, every role, every scope.
