<!-- MAINTAINER / CI-ONLY — first manual watcher pass (W0-T3). Seeds the baseline (W0-T4). -->

# W0-T3 — Baseline Drift Review (2026-06-24)

First manual run of the watcher, done by hand to seed/tune it. Source: live PyPI JSON API +
`az provider show` (authenticated, tenant `1bc0f053…`). Classification per `plan.md`
(minor=auto-PR · major=gated · breaking=gated+blocker).

## SDK packages — pinned vs latest

| Package | Repo pin | Latest (2026-06-24) | Drift | Class | Proposed action |
|---|---|---|---|---|---|
| `agent-framework` | `>=1.2.2` | **1.9.0** | floor ok, 1.2→1.9 jump | major | verify on `latest`; widen tested ceiling after harness green |
| `agent-framework-foundry-hosting` | `==1.0.0a260429` | **1.0.0a260618** | **new alpha** | major | bump in lockstep w/ `agent-framework`; surface re-check (highest churn) |
| `azure-ai-projects` | `>=2.0.0,<3` (code `>=2.2.0`) | **2.2.0** | in range; latest==code floor | minor | no change; note 2.2.0 is now baseline |
| `azure-identity` | `>=1.19.0,<1.26.0a0` | **1.25.3** | in range | none | no change (1.26 not GA) |
| `azure-ai-evaluation` | `==1.16.6` | **1.17.0** | exact pin drifted | major | bump after eval-catalog re-check |
| `langgraph` | `==1.1.8` | **1.2.6** | exact pin drifted | major | bump w/ prebuilt+core lockstep |
| `langgraph-prebuilt` | `==1.0.10` | **1.1.0** | exact pin drifted | major | lockstep |
| `langchain-core` | `==1.3.0` | **1.4.8** | exact pin drifted | major | lockstep |
| `langchain-azure-ai[otel]` | `>=1.2.3` | **1.2.7** | in range | none | no change |
| `azure-ai-agentserver-core` | `==2.0.0b3` | **2.0.0b6** | exact beta drifted | major | bump (LangGraph BYO path) |
| `azure-ai-agentserver-responses` | `==1.0.0b5` | **1.0.0b7** | exact beta drifted | major | bump (LangGraph BYO path) |
| `azure-monitor-opentelemetry` | `>=1.7` | **1.8.8** | in range | none | no change |
| `azure-ai-contentsafety` | `>=1.0.0` | **1.0.0** | exact match | none | no change |
| `azure-search-documents` | `>=11.5` | **12.0.0** | floor ok, **11→12 major** | major | verify direct `SearchClient` usage before widening |

## ARM api-versions — pinned vs latest GA

| Resource type | Repo pin | Latest GA | Latest preview | Class | Proposed action |
|---|---|---|---|---|---|
| `CognitiveServices/accounts` (+`/projects`,`/deployments`) | `2026-03-01` | **2026-05-01** | 2026-05-15-preview | major | bump GA after discovery/identity/capability-host scripts re-verified |
| `Network/virtualNetworks` | `2025-05-01` | **2025-09-01** | — | major | bump after network-walker re-verify |
| `Network/azureFirewalls` | `2025-09-01` | **2026-01-01** | — | major | bump `deep-walk-firewall.sh` after re-verify |
| `Network` service-endpoint policies | `2025-07-01` | (re-check) | — | major | verify on touch |
| Foundry agents data-plane | `2025-11-15-preview` | n/a (data-plane) | — | watch | verify against code-deploy doc + probe |

## Summary

- **0 breaking** (nothing red on the *pinned* set — pins still resolve).
- **~11 major findings** — every exact-pinned SDK and the CognitiveServices + Network api-versions
  have moved. This is the concrete face of "the version is buggy / SDKs are outdated."
- **Highest priority:** `agent-framework` (1.2→1.9) + `agent-framework-foundry-hosting` new alpha —
  these are the load-bearing container-path pins and most likely to have surface changes.

## Important sequencing note (feeds W0-T4)

These are **major** findings → **gated**, and per the fix-lifecycle they must be **validated by the
E2E harness before merge**. The harness (W4) does not exist yet. Therefore:

- We should **NOT blind-bump** pins to latest now — `agent-framework` 1.2→1.9, a new alpha, and
  `azure-search-documents` 11→12 are exactly the kind of jumps that need a real deploy to validate.
  Blind-bumping is the "sloppy shortcut" the maintainer explicitly called out.
- **Recommended baseline (W0-T4):** tag the **current repo state** as the known-good anchor
  (`baseline-vX.Y.0`), with this review captured as the **initial open-findings backlog**. Once W1
  (registry+generator) and W4 (harness) land, this backlog is the watcher's first batch — each bump
  flows through validate-before-merge. The baseline is what we *roll back to*, not what we bump from
  blindly.
