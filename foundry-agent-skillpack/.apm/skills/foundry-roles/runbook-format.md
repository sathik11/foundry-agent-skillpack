# Runbook Handoff Format

When a script preflight fails because the caller lacks a role, the skillpack emits a **runbook block** instead of stopping silently. The block is structured so the dev can copy-paste it into ServiceNow / Jira / Slack to the right persona.

## Format (markdown, paste-ready)

```markdown
### 🔐 Action required: <action_keyword>

| Field | Value |
|---|---|
| Persona | <DevOps / Tenant Admin / Fabric Admin / Network Admin> |
| Required role | <role name> |
| Role ID (if built-in) | <guid> |
| Scope | <full resource path> |
| Granted to | <object id of caller> |
| Why | <one-line: which skillpack step needs it> |
| Expected duration | 5–15 min for RBAC propagation after grant |
| Verify with | `<one-line az / azd command the assignee runs to confirm>` |

**Exact command for the assignee:**

```bash
az role assignment create \
  --assignee-object-id <caller_oid> \
  --assignee-principal-type User \
  --role "<role>" \
  --scope "<scope>"
```

**Then notify the requester** so they can re-run the skillpack step.
```

## Why this shape

- **Persona at the top** — routes the ticket without reading.
- **Role + Role ID + Scope** — copy-paste safe; no name resolution.
- **Granted to** — who the role goes on (the caller running the skillpack, almost always).
- **Why** — single line so reviewers don't need context.
- **Verify** — the command the assignee runs *before* signing off, so the requester isn't told "done" prematurely.
- **Then notify** — closes the loop. RBAC propagation means the requester can't immediately re-run.

## When runbook is emitted

- **Phase 0 Reader missing** → degrade gracefully (checklist), runbook is *informational*, skillpack continues.
- **Phase 1 / 2 / 3 missing** → skillpack **stops**, runbook is the *next step*.
- **Phase 4 / 5 missing** → skillpack **stops** unless explicitly skipped with `--skip-runbook-on=<keyword>`.

## Anti-patterns to avoid

- ❌ Free-text "ask your admin to grant you Foundry access". The assignee has no idea what role on what scope.
- ❌ A bare `az role assignment` command without the verify step.
- ❌ Wrapping the runbook in conversational text — the block must be paste-ready.
- ❌ Emitting the runbook *after* attempting the action and getting a 403. Always preflight first; a 403 in middle of execution leaves dirty state behind.
