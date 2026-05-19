---
title: Brownfield onboarding
description: Onboard existing Python agent code onto Foundry without breaking what already works.
---

You have working Python agent code on your laptop. The skillpack scans it, derives a capability manifest, applies RBAC, deploys, verifies, and sets a drift baseline. Your code does not need to move into the skillpack's templates — it stays the source of truth.

The full step-by-step lives in **Recipe 02** inside the playbook package:

```bash
.agents/skills/foundry-agent-playbook/recipes/02-brownfield-onboarding.md
```

[View the recipe on GitHub →](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/02-brownfield-onboarding.md)

## What's different from greenfield

| Concern | Greenfield | Brownfield |
| --- | --- | --- |
| Source of truth | Templates → derived code | Your existing code |
| `agent-capabilities.yaml` | Authored from interview | Derived from code scan + your edits |
| RBAC | Phase 2 base set | Phase 2 base + Phase 3 per source |
| Failure modes | Template wiring | Self-contained build context (most failures here) |
| Drift baseline | Set at first deploy | Same — set after `/configure-rbac` |

## The brownfield-only step

The skillpack ships a regex code scanner that produces a draft `knowledge.sources[]` block from your existing imports and SDK calls:

```bash
python .agents/skills/foundry-knowledge/scripts/scan_knowledge_refs.py \
    --agent-path agents/<your-name>
```

It surfaces:

- AI Search (`from azure.search.documents`) → `kind: ai_search_direct`
- LangGraph deltalake → `kind: fabric_direct_delta`
- File-search markers → `kind: file_search_basic`
- Ambiguous signals (Blob, Cosmos) → asks you to confirm

**The scan is signal, not source of truth.** Always review every TODO and ambiguous signal before pasting into the manifest.

## After deployment

Recipe 02 ends with **Step 9 — Schedule weekly drift audit**. Once your baseline is set:

```text
/audit-drift agent_path=agents/<your-name> agent_name=<your-name>
```

Wire it into CI as a non-blocking weekly job. Don't gate PRs on it (live state changes without code edits) — gate PRs on `/verify-agent` instead.

## Common brownfield gotchas

| Symptom | Cause | Fix |
| --- | --- | --- |
| `Module not found` after deploy | Code imports from outside `agents/<name>/` | Vendor in or refactor; agent folder is the build context |
| Tool span shows API key auth | Code didn't switch to `DefaultAzureCredential` | Update `main.py`; re-deploy |
| Scanner missed a source you know is there | Regex didn't match (aliased import, conditional, framework-specific) | Add manually to `agent-capabilities.yaml` |
| `agent-status.json` already exists | Same agent path, fresh deploy | OK — `init` is idempotent |

## Then

- Frontend the agent's MCP calls through APIM AI Gateway → [Recipe 05](/recipes/).
- Add a regression-set publish gate → [Recipe 04](/recipes/).
