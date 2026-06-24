<!-- MAINTAINER/CI-ONLY (W5-T2). Time + cost analysis for the standing-vs-ephemeral decision. -->

# E2E Infra — Time & Cost Analysis (W5-T2)

Why the **hybrid** model (standing baseline + ephemeral agent layer) and how we sized the
workflow timeouts + the cleanup sweep. Estimates below are **planning figures** (public Azure
pricing + typical provision durations); the timing harness (see *Measure precisely* §) stamps
real numbers from the first live `provision` into this file.

> Decision driver (from the maintainer): "leaving to setup everytime might lead to time delay…
> APIM provisioning alone might take 15 minutes at times and the job has to wait." → Keep the slow
> layer standing; recreate only the cheap layer per run.

## Provision/teardown time per component (cold)

| Component | Provision (cold) | Teardown | Standing or ephemeral? |
|---|---|---|---|
| Resource group | seconds | seconds | standing |
| AI Foundry account + project | 1–3 min | 1–2 min | **standing** |
| Model deployment (agent-under-test) | 1–2 min | <1 min | standing (cheap, reused) |
| Capability host + Cosmos + Storage | 3–6 min | 2–4 min | **standing** (capHost is delete+recreate only) |
| Azure AI Search (Basic/Standard) | 3–8 min | 2–5 min | **standing** |
| ACR | 1–2 min | 1 min | standing |
| App Insights + Log Analytics | 1–2 min | 1 min | standing |
| **APIM Developer SKU** | **~30–45 min** (can spike) | **~20–40 min** | **standing (the #1 reason for hybrid)** |
| VNet + private endpoints + private DNS | 3–8 min | 3–6 min | standing (private-network scenarios) |
| **Agent layer (`azd up` container/code)** | **2–6 min** | **1–3 min** | **EPHEMERAL — per run** |

**Full cold provision of everything ≈ 45–70 min** (APIM dominates). **Per-run ephemeral agent
cycle ≈ 4–10 min.** Standing the baseline saves ~40–60 min *every* run.

## Workflow timeout sizing (consumed by W3-T3 watchdog + e2e-validate.yml)

| Phase | Budget | Notes |
|---|---|---|
| `baseline ensure` (warm) | 8 min | fast path: existence check + no-op |
| `baseline provision` (cold, manual/dispatch) | 90 min | APIM headroom; never on the hot path |
| agent `azd up` | 15 min | container build + push + deploy |
| `/verify-agent` sentinel | 10 min | incl. cold-start |
| agent `azd down` | 10 min | |
| **per-run E2E job (warm baseline)** | **45 min** | what the twice-weekly schedule uses |

The watchdog must treat "waiting on a known-slow Azure op" (APIM, PE) as **alive, not stalled**
(W3-T3) — these budgets are why.

## Monthly cost of the standing baseline (rough, public list price, single region)

| Component | ~Monthly (USD) | Lever |
|---|---|---|
| APIM Developer | ~$50 | biggest single line; **Consumption SKU ≈ $0 idle** but lacks VNet/features |
| AI Search Basic | ~$75 | drop to Free tier if scenarios allow (limits apply) |
| Cosmos (serverless/small) | $5–25 | serverless keeps idle low |
| Storage + ACR (Basic) | ~$5–10 | |
| Log Analytics + App Insights | $5–30 | ingestion-based; cap with daily quota |
| Foundry account/project | $0 idle | pay per model call |
| Model (agent-under-test) | usage | only during runs |
| **Standing baseline idle** | **~$140–190/mo** | before per-run model/compute |

Per-run marginal cost (model calls + transient compute) is small: **~$1–5 per E2E run**.

### Cost levers if the standing baseline is too expensive
1. **APIM Consumption SKU** for non-private scenarios (~$0 idle) — but it can't do outbound VNet
   integration, so the private-network + inbound-firewall scenarios still need a Developer/v2 tier.
   Compromise: stand APIM up only during the weeks those scenarios run (dispatch `provision`/`destroy`).
2. **AI Search Free tier** when the knowledge scenarios don't exceed its limits.
3. **Schedule-gated teardown**: keep APIM + Search down between runs and pay the ~45 min provision on
   a weekly cadence instead of 24/7 — trades time for money. `baseline.sh provision`/`destroy-all`
   make this a one-command switch.

## APIM: on-demand, not standing (decision)

The standing baseline runs with **`ENABLE_APIM=false`**. APIM only serves **scenario 05 (APIM-fronted
MCP)**. When that scenario is scheduled, bring APIM up incrementally and tear it down after:

```bash
ENABLE_APIM=true  infra/baseline.sh provision      # adds just APIM (~45 min, Developer SKU)
# ...run scenario 05...
# leave it for the week, or remove only APIM when done (manual: az resource delete the APIM instance)
```

This keeps ~$50/mo + the 45-min wait off the 24/7 baseline for a single-scenario dependency.

## Resource discovery: tags, not names (decision)

The vendored modules name globally-unique resources with a `uniqueString(...)` suffix (required so
ACR/APIM names don't collide across tenants). Rather than fight that with date-stamped names — which
is an **anti-pattern**: a date in a resource *name* makes a later re-provision create NEW resources
and orphan the old ones, breaking the standing-baseline model and leaking cost — every resource is
**tagged**:

| Tag | Value | Use |
|---|---|---|
| `createdOn` | `ddMMyyyy` (deploy date, via `utcNow()`) | know when it was created |
| `purpose` | `skillpack-e2e-baseline` | `az resource list --tag purpose=skillpack-e2e-baseline -o table` |
| `managedBy` | `infra/baseline.sh` | distinguish from hand-created resources |
| `azd-env-name` | env name | azd grouping |
| `e2e-ephemeral` | `true` (agent layer only) | the cleanup sweep + `teardown-agents` target ONLY these |

So the human-friendly map is the tag set, and re-provisioning stays idempotent.

## Measure precisely (turns the estimates above into real numbers)

`baseline.sh provision` wraps the deploy; to capture real timings, run it timed and record the ARM
durations:

```bash
time infra/baseline.sh provision
az deployment sub show -n skillpack-e2e-baseline \
  --query "properties.outputs" -o json
az deployment operation group list -g "$AZURE_RESOURCE_GROUP" \
  --query "[].{res:properties.targetResource.resourceType,dur:properties.duration}" -o table
```

Paste the per-resource `duration` column back into the table above and replace "planning figure"
with the measured date. **Until a live provision runs, treat all numbers here as estimates.**
