---
title: Reference — Optional MCP fallback
description: When (and only when) to wire an Azure / Foundry MCP server into your coding host. Scripts are the canonical path; this is opt-in.
---

:::caution[You do not need this for normal use]
The skillpack runs entirely on **convergent scripts + the Foundry SDK**. Every slash command's
primary path is a script. MCP is an **optional, ad-hoc fallback** for a few control-plane commands —
useful only if you have *not* installed the caller-side SDK and want to drive a one-off action by
hand. If you followed [Install](/getting-started/install/), you can skip this page.
:::

## Design boundary

The skillpack deliberately **does not host its own MCP server**. From the [roadmap](/roadmap/):

> Hosting our own MCP server — boundary stays at **"knowledge package + scripts."** If we ever ship
> one, separate repo.

That means: the canonical, supported, CI-tested path for `/setup-evals`, `/configure-rbac`,
`/prepare-deploy`, `/verify-agent`, `/audit-drift`, `/setup-purview`, and `/publish-teams` is the
script under `.agents/skills/<skill>/scripts/`. MCP never gates these — it is a convenience only.

## Two different things people call "MCP"

These are unrelated; don't confuse them:

| | What it is | Where it's configured | Do you need it? |
|---|---|---|---|
| **Control-plane MCP fallback** | An `azure` / `foundry` MCP server your *coding host* can call instead of running a skillpack script (e.g. `mcp_foundry_mcp_continuous_eval_create`) | Your host (opencode / Copilot / Claude / Cursor), host-global | **No** — scripts are canonical. Opt-in only |
| **External MCP as an agent _tool_** | An MCP server (Microsoft Learn MCP, GitHub MCP, an ACA-hosted MCP) that the agent **you build** attaches as a runtime tool | `agent-capabilities.yaml` → `toolbox.mcp_servers[]`, wired into the agent at deploy | Only if your agent needs it. Covered by `/plan-agent` + [foundry-deploy → external MCP](/skills/) |

This page is about the **first** row. For the second, see the greenfield walkthrough (it attaches the
public Learn MCP).

## Which commands carry an MCP fallback

Seven prompts declare optional `mcp:` frontmatter and show a "Legacy fallback (MCP)" block *after*
the script step:

`/audit-drift` · `/configure-rbac` · `/prepare-deploy` · `/publish-teams` · `/setup-evals` ·
`/setup-purview` · `/verify-agent`

Example — `/setup-evals` after its `ensure_continuous_eval.py` step:

> Legacy fallback (MCP, retained for ad-hoc use without the SDK installed):
> `mcp_foundry_mcp_continuous_eval_create(projectEndpoint=…, agentName=…, …)`

## Enabling it (opt-in, per host)

You need two server identities, both maintained outside this repo:

- **`azure`** — the Azure MCP Server (subscription / resource discovery, picklists).
- **`foundry`** — the Azure AI Foundry MCP server (agent + eval control-plane tools).

Install/launch commands come from those servers' own docs — substitute the launch command you get
from them where the examples below say `<server launch command>`.

### opencode

opencode configures MCP **host-global** in `opencode.json`, in a top-level `mcp` block (separate
from any `provider` block):

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "azure":   { "type": "local", "command": ["<server launch command>"], "enabled": true },
    "foundry": { "type": "local", "command": ["<server launch command>"], "enabled": true }
  }
}
```

:::note[Benign install warning on opencode]
When the skillpack installs into opencode, the per-command `mcp:` frontmatter is dropped (opencode
has no per-command MCP binding — MCP is host-global). This warning is **expected and harmless**: the
canonical script path needs no MCP, and if you want the fallback you configure it once here, not
per command.
:::

:::note[Not the same as the E2E driver config]
`tests/e2e/driver/configure-opencode.sh` writes only a `provider.foundry` block — that is the
driver's **LLM brain**, not an MCP server. The driver intentionally wires no MCP, because the
scenarios exercise the canonical script path.
:::

### VS Code (GitHub Copilot)

Add an `.vscode/mcp.json` with a `servers` block:

```json
{
  "servers": {
    "azure":   { "command": "<server launch command>" },
    "foundry": { "command": "<server launch command>" }
  }
}
```

### Claude Code / Cursor / Windsurf

Each reads its own MCP config (`.mcp.json` / `.cursor/mcp.json` / equivalent) with the same
server → launch-command shape. Consult the host's MCP docs; the skillpack does not ship or require
any of these.

## TL;DR

- Default install needs **no MCP**. Run the scripts.
- The MCP fallback exists for SDK-less, ad-hoc, by-hand control-plane calls — opt in per host.
- The opencode `mcp:` frontmatter-drop warning is benign.
- Attaching an MCP **to your agent** (Learn MCP, etc.) is a different feature — see `/plan-agent`.
