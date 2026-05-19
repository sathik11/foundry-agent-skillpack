---
title: What is the skillpack
description: A clear-eyed description of what the Foundry Agent Skillpack is and isn't, and why it exists.
---

The Foundry Agent Skillpack is **markdown skills + slash commands + convergent lifecycle scripts + per-agent durable state** that sits between your coding agent and the Microsoft Foundry hosted-agent surface. It does not deploy your agent — `azd ai agent` does that. It does not run your agent — Foundry does that. What it does is **orchestrate everything around the deploy** so your coding agent can plan → preflight → deploy-handoff → grant → verify → eval → audit safely.

## The boundary

| Layer | Owned by |
| --- | --- |
| Skill / instruction content | This skillpack (markdown loaded into your coding agent's context) |
| Slash commands (`/plan-agent`, `/prepare-deploy`, …) | This skillpack (markdown prompt files) |
| Convergent lifecycle scripts (eval rule create, network detection, RBAC verify) | This skillpack (Python + Bash `ensure_*` scripts) |
| Image build, agent version create, identity assignment | `azd ai agent` extension |
| Agent runtime | Foundry (the hosted container) |
| Foundry-native eval rules + Monitor dashboard | Foundry (we just create the rule via SDK) |
| Per-agent durable state | This skillpack (`agent-status.json` next to your `agent.yaml`) |

The skillpack never runs `az acr build`. It never POSTs to the Foundry control-plane REST API directly. It never issues data-plane queries (no `SearchClient.search(...)`, no SQL against your Lakehouse). Those are the runtime's job, not the skillpack's.

## Why it exists

The Foundry hosted-agent surface is rich but spread across multiple Azure surfaces — Foundry, Purview, Azure AI Search, Fabric, ACR, App Insights, APIM, Entra. Standing up a production-grade hosted agent means coordinating ~40 distinct decisions across those surfaces:

- Which protocol (Responses vs Invocations)?
- Which knowledge sources, with what RBAC?
- Which network class — and which sources are compatible with that class?
- Which eval evaluators, at what sample rate, in which region?
- Which guardrails, at what enforcement mode?
- Which Purview policies?

The skillpack is the place where each of those decisions becomes **declarative** — a row in `agent-capabilities.yaml` — and gets **dispatched** through the lifecycle prompts to the right scripts at the right time.

## What you get on day 1

- 8 slash commands that walk the lifecycle: `/plan-agent`, `/prepare-deploy`, `/configure-rbac`, `/verify-agent`, `/setup-evals`, `/setup-purview`, `/troubleshoot`, `/audit-drift`.
- 15 markdown skills your coding agent loads as needed (e.g., when you ask "how do I attach a Foundry IQ knowledge base," it consults `foundry-knowledge`).
- 1 agent persona (`foundry-engineer.agent.md`) for editor surfaces that support custom personas.
- Vendored runtime middleware (`guardrails.py`, `purview_dlp_middleware.py`) that ships in your agent's container.
- Detection scripts for network class, source RBAC, identities.
- A per-agent state file (`agent-status.json`) that survives across prompt invocations.

## What you do not get

- A runtime. Your agent runs in Foundry's container; the skillpack is build-/deploy-/audit-time only.
- A UI. Reports are markdown files; dashboards are Foundry's Monitor tab + App Insights.
- Microsoft-published guarantees. This is community work; the [roadmap](/roadmap/) tracks the path to Microsoft Learn submission.

## Two packages

The skillpack ships as two installable packages:

| Package | Contents | Required? |
| --- | --- | --- |
| `foundry-agent-skillpack` | Skills, prompts, scripts, persona | Yes — this is the skillpack |
| `foundry-agent-playbook` | Recipes (5 walkthroughs) + runnable fixtures (`learn-agent`, `langgraph-chat-sample`) | Optional — install for learning + smoke tests |

In production, install only the engineering package. In dev / learning / smoke-testing scenarios, install both.

## Read next

- [Personas and roles](/concepts/personas-and-roles/) — who runs what, and how the skillpack handles the handoff.
- [The capability manifest](/concepts/capability-manifest/) — the single declarative file that drives everything.
- [The lifecycle](/concepts/lifecycle/) — what each slash command does and in what order.
