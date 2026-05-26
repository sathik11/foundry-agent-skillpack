---
name: foundry-guardrails
description: Four-layer defense for Foundry agents — vendored middleware, Purview DLP middleware (the unique enforcement gap), Azure Content Safety, and continuous eval / red-team
---

# Foundry Guardrails — Router

| Topic | Read |
|---|---|
| Layer 1 — vendored middleware | [middleware.md](middleware.md) |
| **Layer 1.5 — Purview DLP middleware (unique enforcement gap; Foundry-hosted-only)** | [purview-dlp.md](purview-dlp.md) |
| Layer 2 — Azure Content Safety | [content-safety.md](content-safety.md) |
| Layer 3 — continuous eval + cloud red-team (audited in Foundry) | [foundry-evals](../foundry-evals/SKILL.md) |
| Layer 3 fallback — PyRIT-in-CI (when cloud red-team region not available) | [redteam-evals.md](redteam-evals.md) |
| Capability gates (Phase A/B/C) | [capability-gates.md](capability-gates.md) |
| Vendored middleware code | [scripts/guardrails.py](scripts/guardrails.py) |
| Vendored Purview DLP middleware | [scripts/purview_dlp_middleware.py](scripts/purview_dlp_middleware.py) |
| Red-team CI workflow | [scripts/redteam.yml](scripts/redteam.yml) |
| Phase B grant: Content Safety | [scripts/grant-cs-access.sh](scripts/grant-cs-access.sh) |
| Phase B grant: Purview DLP (tenant-admin runbook) | [scripts/grant-purview-dlp-access.sh](scripts/grant-purview-dlp-access.sh) |
| KQL: guardrail spans | [scripts/kql/guardrail-spans.kql](scripts/kql/guardrail-spans.kql) |

## Four layers — one-line summary

| Layer | What | Latency | Provider |
|-------|------|---------|----------|
| 1 — Vendored middleware | Jailbreak regex, XPIA, length check | sub-ms | Your code |
| **1.5 — Purview DLP middleware** | **PII / PCI / PHI / sensitivity-label enforcement** | ~150–500ms | **Your code calls Purview API** |
| 2 — Azure Content Safety | Violence / Hate / Sexual / SelfHarm classifier | ~150ms | Azure managed |
| 3 — Continuous eval + cloud red-team | Quality + safety drift | hourly/nightly | Foundry |

## Related runtime layer — AGT (Microsoft Agent Governance Toolkit)

The four layers above cover **content-classification + drift** at runtime, and **policy provisioning + capability gates** at deploy time. They do NOT cover **deterministic per-tool-call policy enforcement** (e.g. "this agent is structurally incapable of calling `drop_table`" or "every `send_email` requires human approval").

That layer is owned by [Microsoft Agent Governance Toolkit (AGT)](https://github.com/microsoft/agent-governance-toolkit) — official `microsoft/` org, multi-language SDK, OpenSSF Scorecard, formal RFC 2119 specs. AGT wraps your tool functions inside the agent container:

```python
from agentmesh.governance import govern
safe_tool = govern(my_tool, policy="policy.yaml")  # raises GovernanceDenied if blocked
```

**Recommended posture: adopt and integrate.** AGT is the runtime enforcement layer (effectively *Layer 0* — ordered before our Layer 1). This skillpack is the deploy + lifecycle orchestration layer. Both are needed for production Foundry hosted agents.

**Status today (v0.23.0):** integration is documentation-only. There is no `runtime_governance: agt` key in `agent-capabilities.yaml` yet, no automatic container `requirements.txt` injection, and no agent-template `govern(...)` wraps. **You can use AGT today by adding it to your agent's `requirements.txt` and wrapping tool functions manually.** First-class integration lands in v0.24 — tracked under [TD-29](../../TECHNICAL_DEBT.md#td-29--agt-microsoft-agent-governance-toolkit-as-a-declarable-runtime-governance-layer-open--v024-candidate). See the consumer-facing positioning at [docs → Related work](https://foundry-agent-skillpack.example.com/concepts/related-work/).

## Why Layer 1.5 is unique

Microsoft Purview gives Foundry hosted agents **audit + discovery + classification** out of the box ([foundry-purview/SKILL.md](../foundry-purview/SKILL.md)). It does NOT give them runtime **enforcement** — unlike M365 Copilot agents, which get DLP block / warn enforcement built into the runtime. This middleware closes that gap; it's the one piece of L1.5 you can't replicate by toggling something in a portal.

## Cross-skill references

- Caller-side role preflight → [foundry-roles](../foundry-roles/SKILL.md)
- RBAC for Content Safety → [foundry-identity](../foundry-identity/SKILL.md)
- Purview audit toggle (Layer 1.5 prerequisite) → [foundry-purview](../foundry-purview/SKILL.md)
- Continuous / scheduled / cloud red-team — audited inside Foundry → [foundry-evals](../foundry-evals/SKILL.md)
- Tracing the spans this emits → [foundry-observability](../foundry-observability/SKILL.md)

