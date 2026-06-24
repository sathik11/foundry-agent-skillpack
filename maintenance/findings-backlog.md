<!--
  MAINTAINER / CI-ONLY — durable open-findings backlog.
  The dated files under reviews/ are point-in-time snapshots; THIS file is the rolling,
  stable list the watcher (W2) and fixer (Track B) act on. Each finding gets an ID, a
  status, and links to its fix PR once one exists.
-->

# Open Findings Backlog

Anchored to baseline **`baseline-v0.27.0`** (2026-06-24). Findings flow through the fix-lifecycle
(detect → author on `fix/<id>` branch → validate-before-merge). Status: `open` · `in-pr` ·
`merged` · `wont-fix`. All current entries are the **seed batch** from the W0-T3 review and are
**blocked on the W4 harness** (cannot validate a deploy-affecting bump without it).

| ID | Item | Baseline pin | Upstream (2026-06-24) | Class | Status | Blocked on |
|---|---|---|---|---|---|---|
| F-001 | `agent-framework` | `>=1.2.2` | 1.9.0 | major | open | W4 harness |
| F-002 | `agent-framework-foundry-hosting` | `==1.0.0a260429` | 1.0.0a260618 | major | open | W4 harness (surface re-check) |
| F-003 | `azure-ai-evaluation` | `==1.16.6` | 1.17.0 | major | open | W4 + eval-catalog re-check |
| F-004 | `langgraph` (+prebuilt/core lockstep) | `==1.1.8`/`==1.0.10`/`==1.3.0` | 1.2.6/1.1.0/1.4.8 | major | open | W4 harness (LangGraph path) |
| F-005 | `azure-ai-agentserver-core` | `==2.0.0b3` | 2.0.0b6 | major | open | W4 harness (LangGraph path) |
| F-006 | `azure-ai-agentserver-responses` | `==1.0.0b5` | 1.0.0b7 | major | open | W4 harness (LangGraph path) |
| F-007 | `azure-search-documents` | `>=11.5` | 12.0.0 (11→12) | major | open | W4 + direct-SearchClient audit |
| F-008 | CognitiveServices api-version | `2026-03-01` | 2026-05-01 GA | major | open | re-verify discovery/identity/caphost scripts |
| F-009 | Network/virtualNetworks api-version | `2025-05-01` | 2025-09-01 GA | major | open | re-verify network walkers |
| F-010 | Network/azureFirewalls api-version | `2025-09-01` | 2026-01-01 GA | major | open | re-verify `deep-walk-firewall.sh` |
| F-011 | Network SEP-policy api-version | `2025-07-01` | re-check | major | open | verify on touch |

No-change-needed (in range / exact match as of review): `azure-ai-projects` (2.2.0), `azure-identity`
(1.25.3, ceiling 1.26.0a0), `langchain-azure-ai` (1.2.7), `azure-monitor-opentelemetry` (1.8.8),
`azure-ai-contentsafety` (1.0.0).

## Rules

- A finding is never edited into `main` directly — it becomes a `fix/F-00N` branch + PR.
- `major` findings require the **approval gate** (W6) on top of harness-green.
- When the watcher (W2) re-runs, it reconciles this table: closes `merged` rows, opens new ones,
  and re-stamps `last_verified` in `maintenance/versions.yaml`.
