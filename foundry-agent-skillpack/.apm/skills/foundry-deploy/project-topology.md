# Project topology — what we look at, why, and what the verdicts mean

> **Read this** when you want to know exactly which Azure surfaces `/assess-project` inspects, what api-version each is pinned to, and which skill owns the fix when a verdict is ⚠ or ❌. The interactive prompt is `/assess-project` (defined in [`assess-project.prompt.md`](../../prompts/assess-project.prompt.md)). The discovery primitives are [`scripts/discover-project-topology.sh`](scripts/discover-project-topology.sh) (single ARM walk) and [`scripts/discover-project-topology.py`](scripts/discover-project-topology.py) (verdict formatter).

## Why this exists (separate from `discover-target.sh`)

[`discover-target.sh`](scripts/discover-target.sh) answers **the deploy-time question**: "what is the minimum set of resources I need to deploy a container or code agent?" → account, project, ACR, one model deployment. It is intentionally narrow.

`discover-project-topology.sh` answers **the assessment-time question**: "what is the *full* shape of this Foundry project, and which parts will block, weaken, or simply fail to surface a working agent?" It enumerates connections, capability hosts, network injections, deployments inventory, hosted agents, identity surface, and quota signal — all read-only.

| Scenario | Use… |
|---|---|
| `/plan-agent` Step 0a, `/prepare-deploy` Step 2 | `discover-target.sh` (fast minimum) |
| `/assess-project` (audit, pre-deploy gate, customer-engagement briefing) | `discover-project-topology.sh` |
| `/plan-agent` Step 0a — cached topology pickup (skip re-prompting) | reads `project-topology.md` / `agent-capabilities.draft.yaml` if present in CWD |
| `/prepare-deploy` Step 2 — cross-check declared vs observed | reads cached `project-topology.json` if present |
| `/troubleshoot` — symptom matches a topology gap (e.g., continuous-eval traces missing) | re-runs `/assess-project` or reads cached output |

## Foundry Toolkit boundary (what we do *not* do)

[Foundry Toolkit](https://aka.ms/foundry-toolkit) (formerly AI Toolkit / AITK) already covers a different cut of the same surface. We defer to the Toolkit for **interactive model browsing, ad-hoc model deployment, and the Toolboxes UI**. The skillpack does **not** wrap any of those flows.

| Action | This skillpack | Foundry Toolkit |
|---|---|---|
| Browse model catalog interactively | ❌ defer | ✅ |
| Deploy a model from a card click | ❌ defer | ✅ |
| Wire a Toolbox into a project visually | ❌ defer | ✅ |
| **Verdict** ("Is this project deploy-ready for a hosted agent? What are the top 3 things to fix?") | ✅ owned | ❌ |
| **Stub** (`agent-capabilities.draft.yaml` pre-filled from observed topology) | ✅ owned | ❌ |
| **Cached output reused by `/plan-agent`, `/prepare-deploy`, `/troubleshoot`** | ✅ owned | ❌ |
| **CI gate** (`--out-dir` + `project-topology.json` + `jq` exit-code check) | ✅ owned | ❌ |

When in doubt: use the Toolkit to **provision and visualize**. Use this skillpack to **assess, gate, and integrate into the agent lifecycle**.

## The resource categories — pinned api-versions

Every api-version is pinned per invariant #9 ("never wrap `az rest` in `|| echo '[]'` without stderr capture; pin to current GA or current preview floor"). Stderr is captured and surfaced so an api-version drift fails loudly instead of silently emitting `0` for a category that actually has resources.

| # | Category | Surface | Pinned api-version | Verdict when missing |
|---|---|---|---|---|
| 1 | **Account** | `az cognitiveservices account list` | n/a (CLI) | ❌ no account → exit 3 |
| 1a | **Foundry-grade gate** | account `properties.allowProjectManagement` | n/a (CLI) | ❌ `!= true` → exit 2 |
| 2 | **Project** | `GET …/accounts/{a}/projects` | `2026-03-01` (GA) | ❌ zero projects (cannot host agents) |
| 3 | **Connections** | `GET …/projects/{p}/connections` | `2026-03-01` (GA) | ⚠ zero connections (knowledge / Fabric / external data unreachable) |
| 4 | **Capability hosts** | `GET …/projects/{p}/capabilityHosts` | `2026-03-01` (GA) | ⚠ zero hosts (ephemeral state — memory / thread / vector not bound) |
| 5 | **Network injection** | `GET …/accounts/{a}/networkInjections` | `2026-03-01` (GA) | ⚠ `publicNetworkAccess=Disabled` *without* injection (egress blocked) |
| 6 | **Model deployments** | `az cognitiveservices account deployment list` (per account) | n/a (CLI; underlying GA `2024-10-01`) | ❌ zero deployments (no chat completions available) |
| 7 | **Hosted agents** | `GET <project-endpoint>/assistants` | `v1` (control plane — needs `https://ai.azure.com` audience, see [F-28](../foundry-failure-modes/SKILL.md)) | ✅ zero is normal (greenfield) |
| 8 | **Identity** | account `identity.principalId` | n/a (account body) | ⚠ no system-assigned MI (RBAC fan-out falls back to runbooks) |
| 9 | **Quota signal** | `az cognitiveservices usage list` | n/a (CLI) | (informational only — tolerated empty) |

### Why `2026-03-01` across `projects` / `connections` / `capabilityHosts` / `networkInjections`

`Microsoft.CognitiveServices` ships a unified GA api-version that covers the entire account / project sub-resource graph. We pin all four to the same value so a single bump test moves the whole topology forward. MS Learn enumerates the alternatives (`2025-12-01` GA, `2026-01-15-preview`, `2026-03-15-preview`); the project family converges on `2026-03-01`. If a bump is needed, change the four constants at the top of [`discover-project-topology.sh`](scripts/discover-project-topology.sh) together.

### Why `accounts/projects/agents` is `v1` (not ARM)

Hosted agents live behind the **project endpoint** (`<account>.services.ai.azure.com/api/projects/<project>/assistants`), not under ARM. This is the same control-plane surface `/verify-agent` and `/troubleshoot` hit. The audience must be `https://ai.azure.com` — using the default `https://management.azure.com` token returns `401 Unauthorized` (see [F-28](../foundry-failure-modes/SKILL.md#f-28)). The script handles this via `az account get-access-token --resource https://ai.azure.com`.

## Verdict rubric

Single source of truth — referenced by the docs concept page and by `/troubleshoot`.

| Symbol | Meaning |
|---|---|
| ✅ | Present and shaped as expected for hosted-agent workloads. |
| ⚠ | Present but with caveats the user should consider before deploying. |
| ❌ | Absent or wrong-shape — would cause a known failure if an agent ran today. |

The formatter never says "you must" — verdicts flag gaps and point at the owning skill. The user (or a follow-up `/plan-agent` run) decides what to fix and when.

## Cross-skill ownership map

When a verdict is ⚠ or ❌, the formatter prints the owning reference. Use this map if you are navigating manually:

| Category | Owning skill / doc |
|---|---|
| Account / project / endpoint | [foundry-deploy/SKILL.md](SKILL.md), [`rest-api.md`](rest-api.md) |
| Connections — AI Search, Blob, file-search | [foundry-knowledge/SKILL.md](../foundry-knowledge/SKILL.md) |
| Connections — Fabric / FabricEngagement | [foundry-fabric/SKILL.md](../foundry-fabric/SKILL.md) |
| Capability hosts / `capabilities-manifest` | [capabilities-manifest.md](capabilities-manifest.md) |
| Network injection / publicNetworkAccess / PE | [foundry-prod-readiness/networking.md](../foundry-prod-readiness/networking.md) |
| Model deployments | [model-selection.md](model-selection.md) |
| Hosted agents control plane | [rest-api.md](rest-api.md) + [version-lifecycle.md](version-lifecycle.md) |
| Identity (MI surface, RBAC fan-out) | [foundry-identity/SKILL.md](../foundry-identity/SKILL.md), [foundry-roles/SKILL.md](../foundry-roles/SKILL.md) |
| Continuous-eval gaps surfaced by `/troubleshoot` | [foundry-evals/SKILL.md](../foundry-evals/SKILL.md) |

## Exit codes (for CI / `jq` consumers)

The shell script exits with one of:

| Code | Meaning |
|---|---|
| `0` | Topology emitted (may include ⚠ verdicts). Foundry-grade account found. |
| `2` | Account exists but `allowProjectManagement != true` (not Foundry-grade). |
| `3` | No `Microsoft.CognitiveServices/accounts` in the resource group. |
| `4` | **Ambiguous** — multiple Foundry-grade accounts in the RG (or multiple projects on the chosen account) and no positional `<account_name>` / `<project_name>` hint. Re-invoke with the hint. Candidate names are emitted as `ACCOUNT_NAME_<n>=` / `PROJECT_NAME_<n>=` on stdout BEFORE exit, so `/assess-project` Step 1 (or a CI script) can present a picklist. The script will NEVER silently pick when the RG has multiple Foundry-grade accounts. |

The Python formatter mirrors these codes when invoked standalone (`--input`). A typical CI gate:

```bash
.agents/skills/foundry-deploy/scripts/discover-project-topology.sh "$SUB" "$RG" "$ACCT" "$PROJ" \
  | python3 .agents/skills/foundry-deploy/scripts/discover-project-topology.py \
      --out-dir ./assessment --quiet

# Hard-fail the build if any ❌ verdict landed
jq -e '.verdicts | map(select(.symbol == "❌")) | length == 0' \
  ./assessment/project-topology.json
```

> **CI must always pass `<account_name>` and `<project_name>`.** Auto-pick is an interactive convenience for `/assess-project`, never a CI default — otherwise a new sibling account silently changes which project the gate audits.

## Artifacts written by the formatter

| Path | Purpose | Consumed by |
|---|---|---|
| `project-topology.md` | Human report (✅/⚠/❌ table + Top 3 + per-category detail) | user; `/plan-agent` Step 0a; `/troubleshoot` Scenario 4 |
| `project-topology.json` | Machine-readable equivalent | CI gates (`jq`); `/prepare-deploy` Step 2 cross-check |
| `agent-capabilities.draft.yaml` | Pre-filled stub with discovered values + `# TODO` markers | `/plan-agent` Step 0a (if user opts in) |

The stub is intentionally non-mutating: it lives next to the report, not under `agents/<name>/`. Promoting it to the actual `agent-capabilities.yaml` is a manual `mv` plus user review of every `TODO`.

## What we explicitly do NOT do

- **No mutations.** Read-only. Never calls `PUT` / `POST` / `DELETE`.
- **No model deployment.** Defer to `/plan-agent` Step 0b + `model-selection.md`.
- **No interactive UI.** Defer to Foundry Toolkit for browse / wire flows.
- **No knowledge ingestion scan.** Defer to `foundry-knowledge` brownfield scan + `scan_knowledge_refs.py`.
- **No deep network walk.** Defer to `/prepare-deploy deep_network=true` + `foundry-prod-readiness/scripts/network/*`.
- **No RBAC fan-out.** Defer to `/configure-rbac`.

## When to re-run

- After provisioning a new connection / capability host / model deployment.
- After flipping `publicNetworkAccess` or adding a network injection.
- Before any prod cutover (combine with `/audit-drift`).
- When `/troubleshoot` hits a symptom that matches a topology gap pattern.
