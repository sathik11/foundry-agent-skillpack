# Operator Mode — unified single-operator pattern

> **TL;DR:** When `operator_mode` is `true` (the default since v0.21.0), every script **tries the action first** and only falls back to a runbook if the caller's credentials lack the required role. No more persona assumptions — if you can do it, you do it.

## Why the change

The original skillpack assumed distinct personas: DevOps, Tenant Admin, Fabric Admin, M365 Admin, Network Admin. Scripts that needed a "higher" persona immediately emitted a runbook instead of attempting the operation.

Reality has shifted:
- Platform engineers routinely hold Owner + Purview Admin + Fabric Admin on sandbox/dev subscriptions.
- Even in production, the person running `/configure-rbac` often IS the person who can grant tenant-scoped roles.
- Emitting a runbook when the caller could have just executed the command wastes a round-trip to Slack/ServiceNow and back.

## The pattern: try → execute → fallback

Every grant or configuration script now follows:

```
try-or-runbook.sh <role_hint> <scope_hint> -- <az command...>
```

1. **Try** — run the `az` command.
2. **Succeed** — print `[✓] <action> applied.` and continue.
3. **Fail with 403 / AuthorizationFailed** — emit a paste-ready runbook via `runbook-emit.sh` and exit 1 (so the calling prompt knows to tell the user).
4. **Fail with other error** — print the error and exit 2 (unexpected failure, not a permissions issue).

This replaces the old pattern where scripts would:
1. Check if the caller has the role via `preflight-role.sh`.
2. If no → emit runbook (never try).
3. If yes → execute.

The new pattern is simpler (one code path instead of two) and more accurate (the actual API is the authority on whether you can do the thing, not our role-list heuristic).

## What `operator_mode: false` does

When explicitly set to `false`, scripts revert to the **v0.20 behavior**: preflight-check first, runbook-emit without attempting the action. This is for environments where:
- Attempting an unauthorized call triggers a security alert (SOC monitoring).
- Policy requires a formal approval trail before any mutation (ServiceNow ticket → approval → paste runbook).
- The caller is a service principal with minimal rights that should never attempt elevated actions.

## Affected scripts

| Script | Old behavior | New behavior (`operator_mode: true`) |
|---|---|---|
| `grant-purview-dlp-access.sh` | Always emits runbook (assumes caller lacks Privileged Role Admin) | Tries `az rest` grant first; runbook on 403 |
| `grant-fabric-workspace-role.sh` | Did not exist (TD-1 print-only) | Tries Fabric REST `POST /workspaces/{id}/roleAssignments`; runbook on 401/403 |
| `ensure-provider-registration.sh` | Did not exist (inline in prompts) | Tries `az provider register`; runbook on 403 |
| `preflight-role.sh` | Check-only; exit 1 + runbook when missing | Unchanged (still check-only; the try path is in the grant scripts) |
| `grant-rbac.sh` | Already executes (Phase 1+2) | Unchanged (already auto-executing) |
| `grant-cs-access.sh` | Already executes | Unchanged |

## Prompt integration

Prompts accept `operator_mode` as an input (default `true`):

```yaml
inputs:
  operator_mode: "When 'true' (default), grant scripts attempt the action directly and only emit runbooks on 403. When 'false', scripts preflight-check first and emit runbooks without attempting the action. Set 'false' for SOC-monitored environments where unauthorized attempts trigger alerts."
```

The prompt passes the flag to scripts via environment variable:

```bash
export OPERATOR_MODE=true   # or false
./grant-purview-dlp-access.sh <agent_name>
```

## Boundaries preserved

Operator mode does NOT change:
- **The azd deploy boundary.** APM still never runs `az acr build` or POSTs to `/agents/{name}/versions`. `azd up` owns the container lifecycle.
- **The y/N confirmation on `azd up`.** `/prepare-deploy` Step 6 always asks before deploying.
- **The publish CLI handoff.** `/publish-teams` Step 4 prints the `azd ai agent publish` command; the human runs it.
- **Idempotency guarantees.** All grant scripts remain idempotent (`az role assignment create` tolerates "already exists").

What it DOES change: the **persona assumption** on tenant-scoped, Fabric, and M365 operations. Instead of assuming you can't and printing instructions, it assumes you might and tries.
