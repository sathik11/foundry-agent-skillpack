---
title: Project assessment
description: Read-only Foundry project topology audit — what /assess-project does, the six scenarios it solves, the Foundry Toolkit boundary, and where it does not help.
---

`/assess-project` is the skillpack's **read-only audit** of a Foundry project. It enumerates every resource category that matters to a hosted agent — account, project, connections, capability hosts, network injection, model deployments, hosted agents, identity surface — and emits a verdict report (✅/⚠/❌), a JSON twin for CI gates, and a pre-filled `agent-capabilities.draft.yaml` stub.

It is implemented as a single ARM walk ([`discover-project-topology.sh`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-project-topology.sh)) plus a verdict formatter ([`discover-project-topology.py`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-project-topology.py)). The interactive entry point is the [`/assess-project`](/reference/prompts/#assess-project) prompt.

This page covers the **why** (six scenarios), the **boundary** (what Foundry Toolkit owns vs what this owns), and the **non-goals** (where this does not help). For the schema and api-version pins see [`foundry-deploy/project-topology.md`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/project-topology.md).

## The six scenarios

### Scenario 1 — Portal-provisioned with a silent gap

Someone clicks through the Foundry portal to provision a project. A sub-resource (e.g. Cosmos for a capability host) fails to provision, but the UI marks the project "ready" anyway. The user runs `/plan-agent`, deploys an agent, and only notices when the first turn fails with "thread store unavailable".

`/assess-project` catches this **before** `/plan-agent`. The Capability hosts verdict goes ⚠ ("No capability hosts on the project — memory / thread / vector stores are bound via capabilityHosts. Without one, agents fall back to ephemeral state."), with a reference to `foundry-deploy/capabilities-manifest.md`.

### Scenario 2 — "My use case needs AI Search but I didn't provision one"

The user reads the recipe, sees `knowledge.sources[].type: ai_search`, and starts wiring. `/assess-project` would have listed AI Search as a missing-but-needed connection up front, with a Knowledge / AI Search verdict ❌ and a pointer to `foundry-knowledge/SKILL.md`.

### Scenario 3 — Joining the team six months later

A new engineer inherits a project. The wiki is stale. Instead of clicking through the portal for 20 minutes, they run `/assess-project` and get a one-screen briefing: which knowledge sources exist, which capability hosts are bound, what network class the project sits in, how many model deployments live in the RG, how many agents are already deployed, whether the account MI is reachable.

### Scenario 4 — Continuous-eval traces aren't showing up

`/troubleshoot` matches the symptom to a topology gap pattern (no App Insights connection, no Foundry-grade `allowProjectManagement`, etc.) and re-runs `/assess-project` or reads the cached output. The verdict surface is the same surface `/troubleshoot` already trusts. See the [`/troubleshoot`](/reference/prompts/#troubleshoot) hook.

### Scenario 5 — CI gate before deploy

A pipeline runs `discover-project-topology.sh | discover-project-topology.py --out-dir ./assessment --quiet`, then a one-liner:

```bash
jq -e '.verdicts | map(select(.symbol == "❌")) | length == 0' ./assessment/project-topology.json
```

The pipeline hard-fails if any ❌ verdict landed. No agent ships against a broken project.

### Scenario 6 — Pre-sales / customer engagement

An engineer is on a call. The customer shares their Foundry project. The engineer runs `/assess-project` and reads the verdict table back: "you have AI Search but no capability hosts, no agents on the project yet, and `publicNetworkAccess=Disabled` without an injection — so we should talk about networking before we talk about agents." 30 seconds. Not 20 minutes of portal click-through.

## Verdict rubric

Single source of truth, used by the formatter, by `/troubleshoot`, and by the `foundry-deploy/project-topology.md` reference doc.

| Symbol | Meaning |
| --- | --- |
| ✅ | Present and shaped as expected for hosted-agent workloads. |
| ⚠ | Present but with caveats the user should consider before deploying. |
| ❌ | Absent or wrong-shape — would cause a known failure if an agent ran today. |

The formatter never says "you must" — verdicts flag gaps and point at the owning skill. Remediation is always a separate prompt run.

## Foundry Toolkit boundary

[Foundry Toolkit](https://aka.ms/foundry-toolkit) (formerly AI Toolkit / AITK) covers an overlapping slice of the same surface. We defer to it for **interactive provisioning** and own the **assessment + integration** side.

| Action | This skillpack | Foundry Toolkit |
| --- | --- | --- |
| Browse model catalog interactively | ❌ defer | ✅ |
| Deploy a model from a card click | ❌ defer | ✅ |
| Wire a Toolbox into a project visually | ❌ defer | ✅ |
| **Verdict** ("deploy-ready? top 3 fixes?") | ✅ owned | ❌ |
| **Stub** (`agent-capabilities.draft.yaml` pre-filled from observed topology) | ✅ owned | ❌ |
| **Cached output reused by `/plan-agent`, `/prepare-deploy`, `/troubleshoot`** | ✅ owned | ❌ |
| **CI gate** (`--out-dir` + `project-topology.json` + `jq` exit-code check) | ✅ owned | ❌ |

When in doubt: use the Toolkit to **provision and visualize**. Use this skillpack to **assess, gate, and integrate into the agent lifecycle**.

## Where this does NOT help

- **Mutations.** Read-only. No `PUT` / `POST` / `DELETE`. Bring the gaps to `/plan-agent` or `/prepare-deploy` for remediation.
- **Model deployment.** Defer to `/plan-agent` Step 0b + the `model-selection.md` skill doc.
- **Interactive UI.** Defer to Foundry Toolkit.
- **Knowledge ingestion / indexer scans.** Defer to `foundry-knowledge` brownfield scan + `scan_knowledge_refs.py`.
- **Deep network walk** (NSG / Azure Firewall / SEP). Defer to `/prepare-deploy deep_network=true`.
- **RBAC fan-out.** Defer to `/configure-rbac`.

## What gets written

| Artifact | Purpose | Consumed by |
| --- | --- | --- |
| `project-topology.md` | Human verdict report | user; `/plan-agent` Step 0a; `/troubleshoot` Scenario 4 |
| `project-topology.json` | Machine-readable equivalent | CI gates; `/prepare-deploy` Step 2 cross-check |
| `agent-capabilities.draft.yaml` | Pre-filled stub with `# TODO` markers | `/plan-agent` Step 0a (opt-in) |

## How it plugs into the lifecycle

- **`/plan-agent` Step 0a** — if `project-topology.md` and `agent-capabilities.draft.yaml` exist in CWD, parse them and skip the corresponding interview questions. Only ask about fields the stub left as `TODO`.
- **`/prepare-deploy` Step 2** — if `project-topology.json` exists in CWD, cross-check declared capabilities (manifest) against observed topology and warn on undeclared-but-bound capability hosts.
- **`/troubleshoot`** — when the symptom matches a topology gap pattern (continuous-eval traces missing, capability host not bound, identity surface empty), re-run `/assess-project` or read the cached output.

## Related

- Reference doc — [`foundry-deploy/project-topology.md`](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-deploy/project-topology.md) (api-version table, cross-skill ownership map, exit codes).
- Prompt reference — [`/assess-project`](/reference/prompts/).
- Lifecycle context — [The lifecycle](/concepts/lifecycle/).
- Compare to the minimal deploy-time query — `discover-target.sh` (different scope; see `project-topology.md § Why this exists separate from discover-target.sh`).
