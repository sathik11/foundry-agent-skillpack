# Evaluator Catalog & Capability Mapping

Built-in evaluators referenced by ID + the rules for selecting them from `agent-capabilities.yaml`. The wrappers use this mapping; this doc is the contract.

> Knowledge source kinds referenced below are defined in [foundry-knowledge/SKILL.md](../foundry-knowledge/SKILL.md) and selected via the [decision tree](../foundry-knowledge/decision-tree.md).

## Built-in evaluator IDs

From `azure.ai.projects.models.EvaluatorIds` (azure-ai-projects ≥ 2.0.0). IDs are stable; new ones are added per Foundry release.

### Quality

| ID | What it scores | Inputs |
|---|---|---|
| `relevance` | Response answers the query | query + response |
| `coherence` | Response is well-formed prose | response |
| `fluency` | Grammar / readability | response |
| `groundedness` | Response is supported by retrieved context | query + response + context |
| `task_adherence` | Multi-step instruction following | query + response + (tool calls if any) |
| `intent_resolution` | Captures user's underlying goal | query + response |

### Tooling

| ID | What it scores | Inputs |
|---|---|---|
| `tool_call_accuracy` | Right tool, right args, right order | full trace incl. `gen_ai.tool.*` spans |

### Safety

| ID | What it scores | Inputs |
|---|---|---|
| `violence` | Violence severity 0–7 | response |
| `sexual` | Sexual content severity 0–7 | response |
| `hate_unfairness` | Hate / bias severity 0–7 | response |
| `self_harm` | Self-harm severity 0–7 | response |
| `indirect_attack` | XPIA / prompt injection success | response + tool results |
| `pii_detection` | Detected PII categories in response | response |

### Custom

Register via [Custom Evaluators API](https://learn.microsoft.com/azure/foundry/concepts/evaluation-evaluators/custom-evaluators). Reference by the ID returned at registration. Wrappers detect "not in built-in catalog" and fail fast if the ID is unregistered.

## Capability → evaluator mapping

When `evals.continuous.evaluators` (or `scheduled.evaluators`) is omitted, the wrapper derives the set from the agent's role + declared capabilities. This keeps `agent-capabilities.yaml` short for the common case.

### Base set by `evals.role`

| Role | Default evaluators |
|---|---|
| `orchestrator` | `intent_resolution`, `task_adherence`, `indirect_attack` |
| `ingestion` | `task_adherence`, `tool_call_accuracy`, `indirect_attack` |
| `enrichment` | `groundedness`, `fluency` |
| `narrative` | `coherence`, `fluency`, `relevance`, `hate_unfairness` |
| `prompt` | `relevance`, `task_adherence`, `indirect_attack` (no `tool_call_accuracy` — no tool spans) |

### Capability-driven additions

| When manifest declares… | Add evaluator |
|---|---|
| `toolbox.mcp_servers[]` (any) and role ≠ `prompt` | ensure `tool_call_accuracy` present |
| `knowledge.sources[].kind in {ai_search_direct, foundry_iq, blob_via_indexer, file_search_basic, file_search_standard, sharepoint_via_iq}` | ensure `groundedness` present |
| `knowledge.sources[].kind in {fabric_data_agent, fabric_direct_delta}` | ensure `groundedness` present |
| `guardrails.layers` includes `content_safety` | add `hate_unfairness`, `self_harm` |
| `purview.audit_required: true` | add `pii_detection` |
| `workiq_teams.enabled: true` | add `coherence` |
| `evals.redteam.enabled: true` | (no addition — red-team has its own evaluators) |

De-duplicate. The wrapper prints the final list and asks for confirmation before creating the rule.

## Mapping for the four eval surfaces

| Surface | Evaluator allowed? | Notes |
|---|---|---|
| Continuous eval | ✅ Quality, Safety, Tooling | Sample on live traffic; needs traces present |
| Scheduled eval | ✅ Quality, Safety, Tooling | Run against a dataset; tooling evals require dataset rows that include tool-call expectations |
| Cloud red-team | Safety only (built-in) | Built-in adversarial taxonomy; risk_category + attack_strategy choose the safety dimensions |
| Agent response eval (one-off) | ✅ Quality, Safety, Tooling | Used by `/verify-agent` smoke test after publish |

## Anti-patterns

- ❌ **Mixing built-in and custom IDs in one rule before registering the custom**. Wrapper rejects with the unregistered ID listed.
- ❌ **`groundedness` on an agent with no retrieval context**. Always returns "ungrounded"; clutters dashboards. Wrapper warns when no `knowledge` block is declared.
- ❌ **`tool_call_accuracy` on a `prompt` agent**. No tool spans → 0 score. Wrapper excludes by default for the prompt role.
- ❌ **Pinning `judge_model` to a model that's not deployed in the project**. Eval runs error with `DeploymentNotFound`. Wrapper checks deployment exists at preflight.
