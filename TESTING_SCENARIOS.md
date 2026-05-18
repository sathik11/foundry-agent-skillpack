# Testing Scenarios

End-to-end agent recipes for the Foundry hosted-agent skillpack. **Recipes live in the [foundry-agent-fixtures](foundry-agent-fixtures/) package** — install it to get them locally:

```bash
apm install sathik11/Foundry-Hosted-Agent-Skill/foundry-agent-skillpack
apm install sathik11/Foundry-Hosted-Agent-Skill/foundry-agent-fixtures   # ← brings recipes + fixtures
```

After install, the recipe files land at `.agents/skills/foundry-agent-fixtures/recipes/`.

## Decision tree

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
       Recipe 02           Recipe 01
       (Brownfield)        (Greenfield)
              │                 │
              └────────┬────────┘
                       │
                       ▼
         Then a 3-surface scenario:
         03 — Knowledge + Purview
         04 — AI Search + Scheduled eval
         05 — APIM-fronted MCP + RBAC + Drift
```

## Recipe table

| # | Recipe | Surfaces touched | Fixture? |
|---|---|---|---|
| 01 | [Greenfield quickstart](foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/01-greenfield-quickstart.md) | agent + MCP + middleware guardrails + continuous eval | uses `learn-agent` (after fix-up) OR `langgraph-chat-fixture` |
| 02 | [Brownfield onboarding](foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/02-brownfield-onboarding.md) | code-scan + manifest derivation + RBAC verify + drift baseline | bring-your-own |
| 03 | [Knowledge agent with Purview audit](foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/03-knowledge-with-purview.md) | agent + Foundry IQ KB MCP + Content Safety + Purview audit | recipe only |
| 04 | [AI Search direct + scheduled eval](foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/04-ai-search-with-scheduled-eval.md) | agent + AI Search direct (managed-identity) + scheduled eval gate | recipe only |
| 05 | [APIM-fronted MCP + RBAC + Drift](foundry-agent-fixtures/.apm/skills/foundry-agent-fixtures/recipes/05-apim-fronted-mcp.md) | agent + APIM AI Gateway + per-source RBAC verify + drift baseline | recipe only |

## What every scenario assumes

- Both packages installed.
- `azd ≥ 1.24` with the `azure.ai.agents` extension.
- Azure subscription + Foundry project.
- `Contributor` on the project resource group.

Per-recipe prerequisites (Purview license, AI Search service, APIM instance, etc.) are documented at the top of each recipe.

## Network class testing — separate

Network detection (private endpoints, managed VNet vs BYO VNet, DNS link state, ACR public-access caveat) is its own discipline. Run the detection scripts ad-hoc against any source you've declared:

```bash
# Fast-path checks (always-on)
.agents/skills/foundry-prod-readiness/scripts/network/check-foundry-network-mode.sh <sub> <rg> <foundry-account> [<acr>]
.agents/skills/foundry-prod-readiness/scripts/network/check-source-network.sh <full-resource-id>
.agents/skills/foundry-prod-readiness/scripts/network/check-private-endpoint.sh <full-resource-id>
.agents/skills/foundry-prod-readiness/scripts/network/check-private-dns.sh <vnet-id> <service>

# Deep walkers (opt-in via /prepare-deploy deep_network=true) — NSG / Azure Firewall / SEP analysis
.agents/skills/foundry-prod-readiness/scripts/network/check-source-network.sh <full-resource-id> --deep <agent-subnet-id> [<firewall-id>] <canonical-fqdns...>
.agents/skills/foundry-prod-readiness/scripts/network/deep-walk-nsg.sh <agent-subnet-id> <source-id>
.agents/skills/foundry-prod-readiness/scripts/network/deep-walk-firewall.sh <firewall-id> <canonical-fqdns...>
.agents/skills/foundry-prod-readiness/scripts/network/check-service-endpoint-policy.sh <agent-subnet-id> <source-id>
```

See [foundry-prod-readiness/network-troubleshooter.md](foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/network-troubleshooter.md) for the symptom→fix runbook and [templates/byo-vnet-with-pe.bicep](foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/scripts/network/templates/byo-vnet-with-pe.bicep) for the paste-ready BYO-VNet + PE + Private DNS module.

Network is intentionally not woven into the recipes because failure modes are tenant-specific and the surface evolves. Treat [`foundry-prod-readiness/networking.md`](foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/networking.md) as the source of truth.

## Maintenance

Each recipe carries a `validity_date` header. The daily docs-scan workflow (planned) flags recipes older than 90 days for re-validation against the latest Microsoft Learn surface.
