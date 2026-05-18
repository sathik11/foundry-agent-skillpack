---
title: agent-status.json
description: The durable per-agent state file that survives across prompt invocations.
---

Each hosted agent gets a durable state file at `agents/<name>/agent-status.json`. It records what the lifecycle prompts have done — identities discovered, RBAC granted, network detected, eval rules created, last verify outcome, capability hash baselines for drift detection.

**It is the single mechanism that lets `/audit-drift` know what `/configure-rbac` did 10 minutes ago.**

## File header

Every file starts with schema versioning so consumers can validate without out-of-band lookups:

```json
{
  "_schema_url": "...agent-status-schema.md",
  "schema_version": 1,
  "agent_name": "feedback-harvester",
  "agent_path": "agents/feedback-harvester",
  "agent_kind": "hosted",
  "last_updated": "2026-05-14T10:30:00Z",
  "last_actor": "user@contoso.com"
}
```

## Eight optional sections

Each lifecycle prompt writes one or more sections. Unwritten sections are simply absent.

| Section | Written by | Purpose |
| --- | --- | --- |
| `identities` | `/configure-rbac` | Project MI principal id + per-agent SP principal id |
| `deploy` | `/verify-agent` | Version, image tag, endpoint, deployed-at |
| `preflight` | `/prepare-deploy` | Per-capability ✅/⚠/❌ verdicts from gate dispatch |
| `network` | `/prepare-deploy` | Foundry network class + per-source posture |
| `rbac` | `/configure-rbac` | `phases_completed`, `capability_grants`, `pending` (runbooks) |
| `evals` | `/setup-evals` (planned) | Continuous / scheduled / red-team rule IDs |
| `verify` | `/verify-agent` + `/audit-drift` | Last smoke-test outcome + last drift audit summary |
| `drift` | All three lifecycle prompts | Capability-hash baselines at preflight / RBAC / verify |

## Why three readers minimum

The schema doc enforces a "three readers minimum" rule — a section exists only if at least three prompts will read or write it. This keeps the file from accumulating dead state.

Today:
- `identities` — 3 readers (`/configure-rbac` writes, `/verify-agent` + `/audit-drift` read for cross-reference)
- `rbac.capability_grants` — 3 readers (same)
- `drift.capability_hash_at_*` — 3 readers (`/prepare-deploy` baselines, `/configure-rbac` re-baselines, `/verify-agent` + `/audit-drift` check)

## Commit it

It contains no credentials — only object IDs, principal IDs, role names, network classifications, and hashes. Drift detection requires git history; you commit the file.

If your tenant policy treats principal IDs as sensitive, add it to `.gitignore` and accept losing drift detection.

## The helper is the only writer

`agent_status.py` is the single entry point. Direct edits or `jq` writes from prompts are an anti-pattern — they bypass schema enforcement, atomic writes, and the merge semantics.

```bash
# Read
python .agents/skills/foundry-deploy/scripts/agent_status.py read \
  --agent-path agents/<name> [--field rbac.capability_grants]

# Init (idempotent)
python .agents/skills/foundry-deploy/scripts/agent_status.py init \
  --agent-path agents/<name> --agent-name <name> --agent-kind hosted

# Update a section (deep-merges)
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path agents/<name> \
  --section rbac \
  --json '{"phases_completed": [...]}'

# Surgical set at a dotted path
python .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path agents/<name> \
  --path verify.last_run_status \
  --json '"pass"'

# Capability hash + drift
python .agents/skills/foundry-deploy/scripts/agent_status.py hash --agent-path agents/<name>
python .agents/skills/foundry-deploy/scripts/agent_status.py drift --agent-path agents/<name>
```

## Atomic writes

Every write goes through a `.tmp` file + `os.replace()`. You won't see partial files even if the skillpack is killed mid-update.

## Drift detection

The `drift` section records the SHA-256 (first 12 chars) of `agent-capabilities.yaml` at three lifecycle phases:

```json
"drift": {
  "capability_hash_at_preflight": "a3f29c84b1d0",
  "capability_hash_at_rbac":      "a3f29c84b1d0",
  "capability_hash_at_verify":    "a3f29c84b1d0",
  "drift_detected":               false,
  "drift_fields":                 []
}
```

When the hash differs between phases, `drift_detected: true` + `drift_fields` lists the top-level YAML keys that changed (best-effort — uses `git diff` against HEAD).

## What this file is NOT

- ❌ Not a config file. Foundry runtime never reads it.
- ❌ Not a substitute for `agent-capabilities.yaml`. The capabilities file is intent; this file is observed state.
- ❌ Not authoritative for RBAC. `az role assignment list` is the truth. This is a cache + audit trail.

## Read next

- [The capability manifest](/concepts/capability-manifest/) — what's declared (intent).
- [Lifecycle](/concepts/lifecycle/) — when each section is written.
- [`/audit-drift`](/reference/prompts/) — the read-only reconciler that uses this file.
