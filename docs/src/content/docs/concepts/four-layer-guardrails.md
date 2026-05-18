---
title: Four-layer guardrails
description: Defense-in-depth for Foundry hosted agents — and the unique enforcement gap the skillpack closes.
---

The skillpack ships a four-layer guardrail model. Each layer is independent — declare only what you need.

| Layer | What it catches | Latency | Provider |
| --- | --- | --- | --- |
| **1 — Vendored middleware** | Length explosions, jailbreak regex, XPIA tokens | sub-ms | Your code (vendored) |
| **1.5 — Purview DLP middleware** | PII / PCI / PHI / sensitivity-labelled content | ~150–500ms | Your code calls Purview API |
| **2 — Azure Content Safety** | Violence / Hate / Sexual / SelfHarm severity | ~150ms | Azure managed |
| **3 — Continuous eval + cloud red-team** | Quality + safety drift | hourly / nightly | Foundry-native |

## Why Layer 1.5 is unique

M365 Copilot agents and Copilot Studio agents get **DLP enforcement built into the runtime** — block / warn / audit decisions on prompts and responses based on detected SITs and sensitivity labels. Foundry hosted agents do **not** get this for free.

The skillpack ships a vendored Layer 1.5 middleware that closes that gap. It:

1. Calls Microsoft Purview's classification API per turn (input + response, optionally tool results).
2. Acts on the verdict per `enforcement_mode`: `audit_only` (default, fail-open) / `warn` / `block`.
3. Emits structured OTel spans (`guardrail.purview_dlp.*`) for KQL + dashboards.
4. Refuses to start in `block` mode without explicit `AGREE_PURVIEW_DLP_PREVIEW=1` env var.

This is the single piece of L1.5 you cannot replicate by toggling something in a portal.

## Honest preview limitations (Layer 1.5)

These are real and tracked under TD-4:

- **Token surface.** The Purview classification API may require a Compliance-Admin-tier token, which an agent container shouldn't carry. Middleware uses `DefaultAzureCredential`; users supply elevated SP if their tenant requires it (with the implied risk).
- **Label propagation.** Sensitivity labels follow data via OBO only on the M365 Copilot path. For Foundry hosted with `acl_passthrough: false`, only labels embedded in payload text are detected.
- **Latency.** Two extra API calls per turn. Budget 300–600ms p95 added.
- **API shape stability.** Preview-adjacent; the wrapper is shape-agnostic but the `_classify` method targets the documented `/classify` shape.

## Wire it (in `main.py`)

```python
from guardrails import GuardrailAgentMiddleware
from purview_dlp_middleware import PurviewDLPMiddleware

agent = Agent(
    client=client,
    instructions=INSTRUCTIONS,
    tools=TOOLS,
    middleware=[
        GuardrailAgentMiddleware(agent_name="<name>", mode="entry"),     # Layer 1
        PurviewDLPMiddleware(                                            # Layer 1.5
            agent_name="<name>",
            enforcement_mode="audit_only",
            policies=["dlp-pii-strict"],
        ),
        # Layer 2 (Content Safety) is invoked from inside Layer 1 today.
    ],
)
```

Both middleware files are **vendored** — copied per agent into `agents/<name>/`. Each agent owns its own copy because tunables (BLOCKED_PATTERNS, REFUSAL_TEXT, etc.) vary per agent.

## Layer 3 — eval as a guardrail

Continuous eval and cloud red-team don't block bad responses at runtime — they catch quality and safety drift over time. Wire them via `/setup-evals`; they create Foundry-native `EvaluationRule` and `RedTeam` resources via the `azure-ai-projects` SDK.

Audit lives inside Foundry; results show up in the agent's Monitor tab and the Evaluation tab.

## Verify all four layers

```kql
dependencies
| where cloud_RoleName == "<agent_name>"
| where name startswith "guardrail."
| summarize count() by tostring(customDimensions["guardrail.layer"])
```

Expect ≥ 1 entry per declared layer (`length`, `jailbreak`, `xpia`, `content_safety`, `purview_dlp`).

## What if you don't want all four

Most agents don't need all four. Common combinations:

| Agent shape | Layers |
| --- | --- |
| Quick prototype, sandbox, no sensitive data | 1 only |
| Customer-facing chatbot, no PII | 1 + 2 |
| Internal HR / finance / health agent | 1 + 1.5 + 2 |
| Production prod with regulatory mandate | 1 + 1.5 + 2 + 3 |

Declare only the layers you need in `agent-capabilities.yaml guardrails.layers`. The skillpack's gate dispatch only verifies / grants for declared layers.

## Read next

- [The capability manifest](/concepts/capability-manifest/) — declaring layers.
- [`/setup-purview`](/reference/prompts/) — wires the audit toggle (Layer 1.5 prerequisite).
- [`/setup-evals`](/reference/prompts/) — wires Layer 3.
