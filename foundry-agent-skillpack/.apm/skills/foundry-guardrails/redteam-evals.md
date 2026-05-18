# Layer 3 — Eval & Red-Team

> **Primary path: [foundry-evals](../foundry-evals/SKILL.md).** That skill ships convergent lifecycle scripts for continuous eval, scheduled eval, and cloud red-team. Audit lives inside Foundry.
>
> This file documents the **PyRIT-in-CI fallback** — use it only when the project's region is outside the cloud red-team supported list (currently East US 2 / France Central / Sweden Central / Switzerland West / North Central US).

## When to use this file vs foundry-evals

| Scenario | Use |
|---|---|
| Project in a supported red-team region | **[foundry-evals/redteam.md](../foundry-evals/redteam.md)** — cloud red-team, results in Foundry portal |
| Project NOT in a supported region | This file — PyRIT-in-CI workflow, results in GitHub Actions |
| Want adversarial testing **before** any version is deployed | This file (cloud red-team requires a deployed agent) |
| Need additional adversarial testing on top of cloud red-team | This file (defense-in-depth) |

## Continuous eval — see [foundry-evals/continuous-eval.md](../foundry-evals/continuous-eval.md)

The legacy `mcp_foundry_mcp_continuous_eval_create` MCP call still works but the convergent script at [foundry-evals/scripts/ensure_continuous_eval.py](../foundry-evals/scripts/ensure_continuous_eval.py) is the recommended path — it converges to the desired state, reads `agent-capabilities.yaml`, and validates custom evaluator registration.

## PyRIT-in-CI fallback (this file's scope)

SDK pins:
- `azure-ai-evaluation==1.16.6`
- `pyrit==0.13.0`

Safe attack strategies (production-allowed):
- `EASY` — basic prompt injection
- `MODERATE` — multi-turn social engineering
- `IndirectJailbreak` — XPIA via tool results

CI gate: fail if any `*_asr > 0.05` (5% attack success rate).

Cost: ~$0.50/agent/run with `gpt-5.4-mini` judge.

## CI workflow

Drop-in workflow in [scripts/redteam.yml](scripts/redteam.yml). Runs nightly + on PRs touching `agents/<name>/`.

## Trade-offs vs cloud red-team

| Aspect | PyRIT-in-CI (this file) | Cloud red-team ([foundry-evals](../foundry-evals/redteam.md)) |
|---|---|---|
| Where evidence lives | GitHub Actions artifact | Foundry portal — Evaluation → AI red teaming |
| Audit trail | Outside Foundry | Inside Foundry (compliance-friendly) |
| Region restriction | None (runs in CI runner) | 5 regions today |
| Tests deployed agent | Optional (any HTTP target) | Yes (`AzureAIAgentTarget`, `version=latest` or pinned) |
| Tests pre-deploy versions | Yes — against staging endpoint | No |
| Network-isolated agent support | No (CI can't reach private endpoint) | Yes (uses Foundry-internal egress) |
| Maintenance | You own pyrit version, attack list, judge prompts | Foundry-managed |
