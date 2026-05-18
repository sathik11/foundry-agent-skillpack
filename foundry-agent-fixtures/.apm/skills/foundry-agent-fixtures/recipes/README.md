# Recipe Index

End-to-end walkthroughs that combine the agent runtime with tools/knowledge and at least one outer-loop concern. Each recipe is independent — pick the one that matches your starting point.

> **Validity:** all recipes here valid as of 2026-05-15. Each recipe carries a `validity_date` header.

## Where do I start?

```
            ┌────────────────────────────────────┐
            │  Do you have working agent code    │
            │  on your laptop today?             │
            └────────────────────────────────────┘
                       │
              ┌────────┴────────┐
              │                 │
             YES                NO
              │                 │
              ▼                 ▼
    [02-brownfield-     [01-greenfield-
     onboarding.md]      quickstart.md]
              │                 │
              └────────┬────────┘
                       │
                       ▼
            Pick a 3-surface scenario:
            03 — Knowledge + Purview
            04 — AI Search + Scheduled eval
            05 — APIM-fronted MCP + RBAC + Drift

            Hitting a single-agent wall (latency,
            scope creep, model right-sizing)?
            06 — Multi-agent orchestration with
                 data buffer + SSE streaming

            Then schedule weekly:
            /audit-drift  (read-only reconciliation;
                          see recipe 02 § Step 9)
```

## Recipe table

| # | Recipe | Starting point | Surfaces touched | Fixture? | Validity |
|---|---|---|---|---|---|
| 01 | [Greenfield quickstart](01-greenfield-quickstart.md) | Nothing | agent-framework + Microsoft Learn MCP + middleware guardrails + continuous eval | uses `learn-agent` (after fix-up) OR `langgraph-chat-fixture` | 2026-05-14 |
| 02 | [Brownfield onboarding](02-brownfield-onboarding.md) | Existing Python agent code | Code-scan + manifest derivation + per-skill gate dispatch | bring-your-own | 2026-05-14 |
| 03 | [Knowledge agent with Purview audit](03-knowledge-with-purview.md) | Have a Foundry IQ knowledge base OR can create one | agent + Foundry IQ KB MCP + Content Safety + Purview audit toggle | recipe only | 2026-05-14 |
| 04 | [AI Search direct + scheduled eval](04-ai-search-with-scheduled-eval.md) | Have an AI Search index OR can create one | agent + AI Search direct (managed identity) + scheduled eval gating publish | recipe only | 2026-05-14 |
| 05 | [APIM-fronted MCP + RBAC + Drift](05-apim-fronted-mcp.md) | Have APIM and an existing MCP server | agent + APIM AI Gateway + per-source RBAC verify + drift baseline | recipe only | 2026-05-14 |
| 06 | [Multi-agent orchestration with data buffer + SSE](06-multi-agent-orchestration.md) | Working single agent (recipe 01 or 02 done) hitting a latency / scope / right-sizing wall | orchestrator + N siblings + inter-tool data buffer + SSE streaming + per-sibling identity / RBAC / OTel / continuous eval | recipe only | 2026-05-15 |

## Surface coverage matrix

| Recipe | Agent runtime | Tools / Knowledge | Guardrails | Eval | Red-team | Purview | RBAC verify | Drift |
|---|---|---|---|---|---|---|---|---|
| 01 | ✅ | ✅ MCP | ✅ L1 | ✅ continuous | — | — | implicit | implicit |
| 02 | ✅ | ✅ varies | — | — | — | — | ✅ | ✅ |
| 03 | ✅ | ✅ Foundry IQ | ✅ L2 (CS) | — | — | ✅ audit | implicit | — |
| 04 | ✅ | ✅ AI Search | — | ✅ scheduled (gates publish) | — | — | implicit | — |
| 05 | ✅ | ✅ APIM-fronted MCP | — | — | — | — | ✅ | ✅ |
| 06 | ✅ ×N | ✅ per-sibling | — | ✅ continuous ×N | — | — | ✅ per-sibling | ✅ per-sibling |

Across the six recipes you exercise: every agent runtime template (agent-framework, LangGraph BYO), every knowledge source kind that's tenant-portable (foundry_iq, ai_search_direct, MCP, APIM-fronted MCP), guardrails L1 + L2, continuous + scheduled eval, Purview audit, per-source RBAC verification, the drift baseline mechanism, and — in recipe 06 — multi-agent decomposition with the data-buffer LLM-bypass and SSE streaming.

## Network class testing — separate

Network detection is its own discipline (private endpoints, managed VNet vs BYO VNet, DNS link state, ACR public-access caveat). Run the four detection scripts against any source you've declared:

```bash
.agents/skills/foundry-prod-readiness/scripts/network/check-foundry-network-mode.sh <sub> <rg> <foundry-account> [<acr>]
.agents/skills/foundry-prod-readiness/scripts/network/check-source-network.sh <full-resource-id>
.agents/skills/foundry-prod-readiness/scripts/network/check-private-endpoint.sh <full-resource-id>
.agents/skills/foundry-prod-readiness/scripts/network/check-private-dns.sh <vnet-id> <service>
```

Network is intentionally not woven into the recipes because the failure modes are tenant-specific and the surface evolves. Treat `foundry-prod-readiness/networking.md` as the source of truth.

## What every recipe assumes

- You've installed both packages: `foundry-agent-skillpack` + `foundry-agent-fixtures`.
- You have `azd ≥ 1.24` with the `azure.ai.agents` extension installed.
- You have an Azure subscription with a Foundry project.
- You're logged in: `az login` and `azd auth login`.
- You have at least `Contributor` on the resource group containing your Foundry project.

Recipes specify additional prerequisites (Purview license, AI Search service, APIM instance, etc.) at the top of each file.
