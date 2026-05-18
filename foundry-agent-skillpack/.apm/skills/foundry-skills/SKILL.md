---
name: foundry-skills
description: Native file-based agent skills (SkillsProvider pattern from agent-framework) — bundle a SKILL.md + scripts inside the agent container so the model can discover and invoke domain-specific actions without ad-hoc tool plumbing.
---

# Foundry Skills (Native File-Based)

> Source of truth: [Sample 07 — Skills (foundry-samples)](https://github.com/microsoft-foundry/foundry-samples/tree/main/samples/python/hosted-agents/agent-framework/responses/07-skills). Validity 2026-05-14.

A *skill* is a `SKILL.md` + scripts folder bundled inside the agent's container. The agent-framework `SkillsProvider` discovers skills at startup, advertises them to the model, and your script runner executes them when the model picks one. Same authoring pattern your APM tooling uses for *Claude*-style skills — but loaded at agent runtime, not by an IDE.

> ⚠️ Don't confuse these with the **APM skills** in this package (`.apm/skills/`). Those teach your *coding agent* about Foundry. This file is about skills *inside a hosted agent* that teach the *runtime agent* about your domain workflows.

## When to use a skill vs. a tool vs. an MCP server

| Need | Use |
|---|---|
| One Python function the model calls with structured args | `@tool` |
| External system already speaks MCP (or you want to share with multiple agents) | MCP server (see [external-mcp.md](external-mcp.md)) |
| **Multi-step workflow with instructions + bundled scripts + non-Python deps** | **Skill** |
| Output that needs `$HOME`-based file persistence (PDFs, reports, generated assets) | **Skill** (uses Foundry hosted-agent `$HOME` convention) |
| Quick one-off — keep prompt-only with `instructions` | No skill needed |

The skill pattern shines when the model needs **instructions on when/how to use the workflow** alongside **the actual code that performs it**. A bare `@tool` lacks the procedural guidance; an MCP server is overkill if the workflow is internal to one agent.

## Anatomy

```
agents/<name>/
├── main.py
├── Dockerfile
├── requirements.txt
└── skills/                              ← agent-framework SkillsProvider scans this
    └── travel-guide/                    ← one folder = one skill
        ├── SKILL.md                     ← REQUIRED: name, description, workflow, scripts
        └── scripts/
            └── create_travel_guide.py   ← runnable; invoked via your script_runner
```

`SKILL.md` frontmatter (YAML) is the contract:

```markdown
---
name: travel-guide
description: Creates colorful PDF travel guides for cities, including itinerary ideas,
  neighborhoods, food, practical tips, and photo-worthy stops. Use when the user
  asks for a travel guide, city guide, itinerary, trip plan, or PDF document for
  a destination.
---

# Travel guide skill

## Workflow

1. Identify the city or destination from the user's request.
2. Infer the trip length and interests when provided. Default to 3 days.
3. Run the PDF generator script:
   - skill name: `travel-guide`
   - script name: `scripts/create_travel_guide.py`
   - args:
     - `city`: destination city, required
     - `days`: number of itinerary days, optional, defaults to `3`
     - `interests`: comma-separated interests, optional
     - `tone`: guide style such as `family-friendly`, `luxury`, `budget`, optional
4. After the script returns, tell the user the `$HOME`-based PDF path.

## Available scripts

- `scripts/create_travel_guide.py` — Generates a colorful PDF travel guide and
  returns JSON with the saved file path.

## Example script arguments

```json
{ "city": "Lisbon", "days": 3, "interests": "food,viewpoints,neighborhoods" }
```
```

The frontmatter `description` is what the model sees when deciding to use the skill — write it like a tool description, action-oriented and trigger-rich.

## Wiring (`main.py`)

The minimum viable hosted agent with skills:

```python
from agent_framework import Agent, SkillsProvider
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential
from pathlib import Path

# (see scripts/example-script-runner.py for the full implementation)
from skill_runner import run_local_skill_script

client = FoundryChatClient(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
    credential=DefaultAzureCredential(),
)

skills_provider = SkillsProvider.from_paths(
    skill_paths=Path(__file__).parent / "skills",
    script_runner=run_local_skill_script,
)

agent = Agent(
    client=client,
    instructions="You are a travel planner. Use the travel-guide skill when asked for a PDF guide.",
    context_providers=[skills_provider],
    default_options={"store": False},
)

ResponsesHostServer(agent).run()
```

Three things to know:

1. **`context_providers=[skills_provider]`** — that's how skills land in the model's context. Don't pass them via `tools=`; that's a different mechanism.
2. **`script_runner` is YOUR code** — the framework discovers the skill but won't execute the script for you. The runner enforces what's safe to run, what timeout applies, what env vars leak in, etc. **Treat it as a security boundary.**
3. **Skills are on the container's filesystem** — they're shipped as part of the image. Read-only at runtime. Update by building a new image + creating a new agent version.

## The script runner is the security boundary

A copy of the canonical runner pattern lives at [scripts/example-script-runner.py](scripts/example-script-runner.py). Hard rules baked into it:

- ✅ Only execute scripts whose path resolves *inside* the skill's directory (path-traversal guard).
- ✅ 60-second timeout per script.
- ✅ `capture_output=True` — never inherit stdin/stdout/stderr from the agent process.
- ✅ Shell out to `sys.executable` — same Python; same venv; same dependencies.
- ❌ No `shell=True`. Ever.
- ❌ No interpolation of model-supplied strings into the command line beyond CLI flag values (still escaped by `subprocess`).
- ❌ Don't add scripts that talk to internal services without explicit identity scoping; the script runs as the agent's process identity.

**If you allow non-Python scripts** (bash, node, etc.), extend the runner with a per-extension allowlist and per-extension interpreter. Don't infer interpreter from shebang — the agent could write a malicious one. (Skills are *bundled in the image*, so this is mostly theoretical, but the runner is the one place to enforce it definitively.)

## Where outputs go: `$HOME` is the contract

Foundry hosted agents persist `$HOME` and `/files` across turns and idle deprovisioning (up to 30 days; 15-min idle window). For Skills:

- ✅ Write generated artifacts (PDFs, CSVs, etc.) to `$HOME/<skill-output-dir>/`.
- ✅ Return the `$HOME`-based path to the model so it can tell the user where to find it.
- ✅ Same path is reachable across follow-up turns of the same conversation/session.
- ❌ Don't write outside `$HOME` or `/files` — anything else gets blown away on resume.
- ❌ For durable external sharing (signed URL, etc.), upload to Storage from the script and return the URL instead.

See [Manage hosted agent sessions](https://learn.microsoft.com/azure/foundry/agents/how-to/manage-hosted-sessions) for the full session lifecycle.

## Bundling skills into the image

`Dockerfile` snippet (the existing template's `COPY *.py ./` would miss the `skills/` folder — be explicit):

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY *.py ./
COPY skills/ ./skills/
EXPOSE 8088
CMD ["python", "main.py"]
```

If the skill needs non-Python deps (e.g., `wkhtmltopdf`), install in the image:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends wkhtmltopdf && rm -rf /var/lib/apt/lists/*
```

Then declare the skill's runtime needs in `SKILL.md` for future maintainers (not the model).

## Versioning

- **Skills version with the agent image.** Editing a skill = building a new image = creating a new agent version. There's no live skill-reload mechanism.
- Bump the agent's image tag (`agent:v3 → agent:v4`) when skill behavior changes; keep the version semantically meaningful.
- If multiple agents share a skill, vendor it (copy) into each agent — there's no skill registry today. Cross-agent reuse → MCP server.

## Capability manifest

Skills are intentionally NOT a top-level block in `agent-capabilities.yaml`:
- They're invisible to RBAC (no per-skill grants — they run as the agent's identity).
- They're invisible to the network preflight (no per-skill resources).
- They're invisible to evals (the model invokes them like any other tool — `tool_call_accuracy` covers them via the script-runner span name).

If a skill calls an external API, **that** API gets a row in `knowledge.sources[]` or `toolbox.mcp_servers[]` — not the skill itself.

## OTel and verification

The script runner emits a span when it shells out. Recommended attributes:

```python
# Inside run_local_skill_script:
from opentelemetry import trace
tracer = trace.get_tracer(__name__)

with tracer.start_as_current_span(f"skill.{skill.name}.{script.path}") as span:
    span.set_attribute("skill.name", skill.name)
    span.set_attribute("skill.script", script.path)
    span.set_attribute("skill.args_count", len(args or {}))
    # ... subprocess.run(...)
    span.set_attribute("skill.exit_code", completed.returncode)
```

Verify in App Insights:

```kql
dependencies
| where cloud_RoleName == "<agent_name>"
| where name startswith "skill."
| project timestamp, name, customDimensions["skill.name"], customDimensions["skill.exit_code"], duration
| order by timestamp desc | take 20
```

Also fold into evaluator selection — the existing `tool_call_accuracy` evaluator scores tool/skill invocations the same way (a skill is a `gen_ai.tool.call` from the model's perspective).

## Anti-patterns

- ❌ **Reading model output as a path and `subprocess.run`-ing it.** The runner must constrain to declared scripts only.
- ❌ **Letting scripts write to `/tmp` and forgetting they vanish on idle deprovisioning.** Use `$HOME`.
- ❌ **Skills that depend on per-conversation env vars set at deploy time.** Env vars are agent-version-scoped, not session-scoped.
- ❌ **Mixing skills and prompt-agent definition (`agent-definition.yaml`).** Skills are an `agent-framework` SDK pattern — only hosted (container) agents use them today. Prompt agents on Foundry don't have an equivalent.
- ❌ **Encoding business logic in `SKILL.md` workflow steps that the model can be tricked into skipping.** Put guardrails in the script.

## Cross-skill references

- Hosted-agent SDK surface and image build → [foundry-deploy/sdk-surface.md](sdk-surface.md)
- Tool-calling vs MCP vs skill decision → [external-mcp.md](external-mcp.md)
- Session / `$HOME` lifecycle → [foundry-deploy/sessions-vs-conversations.md](sessions-vs-conversations.md) *(planned)*; for now see [Microsoft Learn: Manage hosted agent sessions](https://learn.microsoft.com/azure/foundry/agents/how-to/manage-hosted-sessions)
- Eval coverage for tool/skill calls → [foundry-evals/evaluator-catalog.md](../foundry-evals/evaluator-catalog.md) (`tool_call_accuracy`)
- Why skills are NOT in `agent-capabilities.yaml` → see "Capability manifest" above
