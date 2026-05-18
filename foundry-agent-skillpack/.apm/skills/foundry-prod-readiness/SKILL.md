---
name: foundry-prod-readiness
description: Network classes (managed VNet / BYO VNet / public), cost model, capacity planning, SLO targets, and production hardening for Foundry hosted agents
---

# Foundry Production Readiness — Router

| Topic | Read |
|---|---|
| Network classes, managed VNet, BYO VNet, ACR caveat, Fabric Data Agent block, FQDN allowlist | [networking.md](networking.md) |
| Network detection scripts (foundry mode, source posture, PE state, DNS link) | [scripts/network/](scripts/network/) |
| **Deep-network walks (NSG / Azure Firewall / Service Endpoint Policy) — opt-in via `--deep`** | [network-troubleshooter.md](network-troubleshooter.md) |
| **Paste-ready BYO VNet + PE Bicep scaffold (hand-off, not auto-provisioned)** | [scripts/network/templates/byo-vnet-with-pe.bicep](scripts/network/templates/byo-vnet-with-pe.bicep) |
| Eval / red-team region restrictions and propagation timing | [foundry-evals](../foundry-evals/SKILL.md) |
| Required roles for network operations | [foundry-roles/role-matrix.md Phase 4](../foundry-roles/role-matrix.md) |

## Networking — quick reference

Three deployment classes. **Outbound mode is immutable post-deploy** — pick before `azd up`.

| Class | Inbound | Outbound | When |
|---|---|---|---|
| Public | Public | Public | Sandbox / dev |
| Managed VNet | Public PNA-controlled | MSFT-managed VNet + managed PEs | Default for prod |
| BYO VNet | PE into your VNet | Subnet-injected (`Microsoft.App/environments`, /27+) | Regulated workloads |

Canonical gotchas:
1. **ACR must be public-network-enabled** — even with private Foundry. (Hosted agents requirement.)
2. **Fabric Data Agent does NOT work** in network-isolated agents.
3. **PEs to Storage / AI Search / Cosmos are NOT auto-created** — provision in those resources' own pages.
4. **DNS misresolution is the #1 silent failure** — `nslookup` from inside the VNet must return a private IP.

Full detail + exit conditions: [networking.md](networking.md).

## Cost model

| Component | Billing |
|-----------|---------|
| Agent compute | Scale-to-zero (no cost when idle, 15-min timeout) |
| LLM inference | Per-token — largest cost driver |
| ACR | ~$5-20/mo |
| App Insights | ~$2.30/GB after free 5GB |
| Cosmos (serverless) | ~$0.25/100K RUs |
| Content Safety | ~$1/1K records |

### Right-Size Models
- nano: high-volume ingestion
- mini: scoring, enrichment
- chat: narrative, complex analysis
- reasoning: deep multi-factor analysis

### Cost Optimization
- Middleware short-circuit: zero LLM tokens for deterministic tasks
- Payload truncation: 60-80% fewer input tokens
- Inter-tool buffer: eliminates redundant serialization tokens

## Capacity planning

| Component | Value |
|-----------|-------|
| Cold start | 15-25s per agent |
| 5-agent pipeline | 8-12 min total |
| Concurrent invocations | Platform-managed (no config) |
| Min replicas | 0 (scale-to-zero only in preview) |
| Idle timeout | ~15 minutes |

Pre-warm by sending dummy invocation before peak usage.

## SLO targets (suggested)

| Metric | Target |
|--------|--------|
| Agent availability | 99.5% |
| Pipeline completion | 95% |
| P95 latency | <12 min |
| Cold-start P95 | <30s |
| Guardrail false-positive rate | <1% |
| Eval quality scores | >3.0/5.0 |

## Hardening checklist

- [ ] Retry logic on all sub-agent calls (5x backoff)
- [ ] Deterministic fallback for NL2SQL
- [ ] Payload truncation (<30 records)
- [ ] SSE streaming for pipelines >120s
- [ ] `ENABLE_INSTRUMENTATION` + `ENABLE_SENSITIVE_DATA` set (OTel; not eval — see [foundry-evals](../foundry-evals/SKILL.md))
- [ ] Guardrails wired (L1 + L2)
- [ ] Continuous eval rule created via `ensure_continuous_eval.py` ([foundry-evals](../foundry-evals/SKILL.md))
- [ ] Cloud red-team scan in place (region-permitting; ASR < 5%)
- [ ] Timestamped image tags
- [ ] Deploy script preserves all env vars
- [ ] Network class chosen and documented in `agent-capabilities.yaml network` block ([networking.md](networking.md))
- [ ] All four network detection scripts pass for declared sources ([scripts/network/](scripts/network/))
