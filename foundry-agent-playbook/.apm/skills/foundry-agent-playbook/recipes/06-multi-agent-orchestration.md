---
validity_date: 2026-05-15
audience: You have a working single agent (recipe 01 or 02 done) and need to decompose into a sibling pipeline because latency, scope, or right-sizing forces it
duration: ~90 minutes
surfaces: [agent_framework_runtime, sibling_orchestration, inter_tool_data_buffer, sse_streaming, per_agent_otel, per_agent_continuous_eval]
prerequisites:
  - Recipe 01 or 02 completed (you have a single working hosted agent)
  - At least 2 model deployments in your Foundry account (recommended tiering — `gpt-4.1-nano` for ingestion, `gpt-4.1-mini` for scoring; reasoning model only if a sub-agent genuinely needs it)
  - `Cognitive Services Contributor` on the Foundry account *only if* Step 1 needs to deploy an extra model for you
  - You have observed at least one of these symptoms in the single agent: end-to-end latency > 60s, the agent has to do >3 distinct kinds of work, or you want to right-size models per task
---

# Recipe 06 — Multi-Agent Orchestration with Data Buffer + SSE Streaming

> **👋 Brand new to Foundry?** This recipe assumes you've already deployed at least one working hosted agent — its prerequisites build on the lifecycle (`/plan-agent` → `/prepare-deploy` → `azd up` → `/configure-rbac` → `/verify-agent`) that Recipe 01 walks you through end-to-end. If you've never deployed a Foundry hosted agent before, **start with [Recipe 01 — Greenfield quickstart](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/01-greenfield-quickstart.md)** (~30 min) and come back here after.

> **Goal:** Decompose a single agent that is hitting a wall (latency, scope creep, model right-sizing) into an orchestrator + N sibling sub-agents, using the inter-tool **data buffer** pattern to bypass the LLM serialization bottleneck and SSE streaming to survive long pipelines. End state: 9-minute end-to-end pipeline with per-sub-agent OTel spans, per-sub-agent continuous eval, and orchestrator + sibling identities/RBAC graduated to production-shape.

This recipe is **not** about going multi-agent for its own sake. It's the recipe you reach for once a single agent has earned the right to be split — and you need to do it without breaking observability, RBAC, or eval coverage.

You write more code than in recipes 01–05 because the `agent-framework` template scaffolds a single agent. The *orchestration glue* (sibling invocation, retry, response extraction, data buffer) is yours to write — but the patterns and code shapes come from `foundry-multi-agent`.

## When this recipe applies (and when it does not)

| Symptom in your single agent | Does this recipe help? |
|---|---|
| Total response time 30-60s, mostly LLM thinking | **No** — first try a smaller / faster model and middleware short-circuit ([Pattern 1c](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-patterns/SKILL.md)) |
| Agent does 3+ distinct kinds of work (harvest + score + narrate) and reasoning bleeds across them | **Yes** — sibling decomposition lets each sub-agent own its job |
| Orchestrator passes 25+ records / 20KB+ between tool calls; latency spikes by 40-60s per hop | **Yes** — this is the data-buffer pattern, the core motivation |
| Pipeline runs > 120s end-to-end, SSE stream times out | **Yes** — Step 5 covers SSE streaming and timeout config |
| You want different models per task (nano for harvest, mini for score, chat for narrate) | **Yes** — sibling decomposition is the only way to right-size per task |
| You want one agent to "delegate" to another in a chat loop | **No** — that's Pattern 2d (peer-to-peer A2A), not covered here |

## Surface map

| Surface | Choice |
|---|---|
| Orchestrator runtime | `agent-framework` (hosted, single Foundry agent kind = `hosted`) |
| Sub-agent runtime | `agent-framework` (hosted, one per sibling — they're peers, not children) |
| Inter-agent transport | Foundry Responses API (`{EP}/agents/{name}/endpoint/protocols/openai/responses?api-version=v1`) |
| Data plumbing | Inter-tool **data buffer** (module-level dict; LLM bypass for >25 records / >20KB) |
| Long-pipeline transport | SSE streaming with three-tier response extraction |
| Per-sibling outer loop | OTel spans (one `execute_tool` per sibling call) + continuous eval per agent |
| Identity | One Entra Agent ID per agent (orchestrator + each sibling) |
| RBAC | Per-agent service-principal grants (orchestrator does NOT inherit sub-agent grants) |

Reference: every code shape in this recipe traces to [foundry-multi-agent/SKILL.md](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-multi-agent/SKILL.md). The pattern decision matrix is in [foundry-patterns/SKILL.md § Multi-Agent Patterns](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-patterns/SKILL.md).

---

## The example we'll build

A 4-stage **customer-feedback pipeline**:

```
                ┌─────────────────────────────────────┐
                │  Orchestrator (gpt-4.1-mini)        │
                │  Decides which siblings to call &   │
                │  in what order. Sees ONLY summaries.│
                └──┬──────────────────────────────────┘
                   │ invoke_harvester(query)
                   ▼  (returns "{status:success, count:119}")
       ┌────────────────────────┐         ┌─────────────────┐
       │  Harvester             │ ──────► │ _DATA_BUFFER    │
       │  gpt-4.1-nano, ~30s    │  full   │ (module-level)  │
       │  Pulls 119 records     │  data   │                 │
       └────────────────────────┘         └─────────────────┘
                   │                              ▲
                   │ invoke_sentiment()           │ reads full data
                   ▼  (returns "{status:success}")│ bypassing LLM
       ┌────────────────────────┐                 │
       │  Sentiment Scorer      │ ────────────────┘
       │  gpt-4.1-mini, ~120s   │
       └────────────────────────┘
                   │ invoke_narrator()
                   ▼
       ┌────────────────────────┐
       │  Narrator              │ ──► returns final text to orchestrator
       │  gpt-4.1-mini, ~90s    │
       └────────────────────────┘
```

Pipeline budget: ~4 minutes. We'll add a 4th sub-agent (priority scorer, reasoning model, ~180s) in Step 6 to cross the 120s SSE-timeout threshold and demonstrate streaming.

### Why we ship a synthetic fixture

A multi-agent recipe is only useful if you can actually *run* it. To avoid making you stand up a CRM, AI Search index, or Fabric workspace just to learn the pattern, the playbook package ships a **synthetic feedback dataset** — 30 anonymised records (12 positive, 10 negative, 8 neutral) across `support_ticket / app_review / twitter / email_survey` channels for a hypothetical SaaS product. The harvester reads from this fixture; the other siblings see whatever the harvester returns.

When you're done validating the pattern, swap the harvester's data source for your real one — Step 3 has the explicit swap point flagged. The orchestrator, sentiment, narrator, identity/RBAC/OTel/eval wiring all stay identical.

---

## Step 0 — Bootstrap the synthetic feedback fixture

Copy the shipped fixture into the harvester's container:

```bash
mkdir -p agents/feedback-harvester/fixture
cp .agents/skills/foundry-agent-playbook/fixtures/feedback-fixture.json \
   agents/feedback-harvester/fixture/feedback.json
```

(`.agents/skills/foundry-agent-playbook/` is where APM installs the playbook package; if you're scripting around this, the source path inside the repo is `foundry-agent-playbook/.apm/skills/foundry-agent-playbook/fixtures/feedback-fixture.json`.)

Sanity-check the fixture:

```bash
python -c "import json; d=json.load(open('agents/feedback-harvester/fixture/feedback.json')); print(len(d), 'records,', sum(1 for r in d if 'love' in r['text'].lower() or '5 stars' in r['text'].lower()), 'obviously positive')"
# Expected: 30 records, 2 obviously positive
```

✅ **Checkpoint.** `agents/feedback-harvester/fixture/feedback.json` exists, contains 30 records, each with `id / timestamp / customer / channel / text`.

> **Want to use your own data instead?** Skip this step. In Step 3 you'll replace the harvester's `tools.py` with a call to your real source (MCP server, AI Search query, Fabric notebook). The rest of the recipe is unchanged.

---

## Step 1 — Plan all four agents (`/plan-agent` × 4)

Run `/plan-agent` once per agent. Give each its own directory and `agent-capabilities.yaml`. They are independent agents from Foundry's perspective.

```bash
# Orchestrator — calls siblings as tools, no business logic of its own
/plan-agent agent_name=feedback-orchestrator description="Coordinates a feedback-analysis pipeline. Calls harvester, sentiment, narrator siblings in order. Returns a synthesized customer-feedback report."

# Sub-agents
/plan-agent agent_name=feedback-harvester description="Pulls customer feedback rows from a data source for a given query window. Returns raw JSON records only."
/plan-agent agent_name=feedback-sentiment description="Classifies a list of feedback records as positive/negative/neutral with a 1-line rationale per record. Returns raw JSON records only."
/plan-agent agent_name=feedback-narrator description="Generates an executive summary from a list of scored feedback records. Returns markdown."
```

For each, accept defaults except:
- **Pattern**: orchestrator → Pattern 2a (Sequential Fan-out); siblings → Pattern 1a
- **Model**: orchestrator → `gpt-4.1-mini`; harvester → `gpt-4.1-nano`; sentiment → `gpt-4.1-mini`; narrator → `gpt-4.1-mini`
- **Capabilities — by sibling**:
  - **Harvester**: declares `toolbox.enabled: false`. It has no MCP — it has one `@tool` function (`fetch_feedback`) that reads from the fixture file you bootstrapped in Step 0. You'll add that function in Step 3.
  - **Sentiment + Narrator**: declare `toolbox.enabled: false` AND have **no `@tool` functions at all**. The LLM's `instructions` field does all the work — sentiment classifies the JSON it receives, narrator writes the markdown summary. (In `agent-framework`, you only need a `@tool` when the agent has to call an external system or perform a side effect. Pure-reasoning agents need no tools.)
  - **Orchestrator**: declares `toolbox.enabled: false`. Its three "tools" are the sibling-invocation `@tool` wrappers you'll add in Step 2 — they live in `main.py`, not in the capability manifest.
- **Continuous eval**: enable on **every** agent (orchestrator quality is independent of sibling quality; you need separate scores).

✅ **Checkpoint.** Four directories under `agents/`:

```
agents/
├── feedback-orchestrator/
├── feedback-harvester/
├── feedback-sentiment/
└── feedback-narrator/
```

Each with its own `agent-capabilities.yaml`, `agent.yaml`, `main.py`, `Dockerfile`. Open each `agent-capabilities.yaml`; the `target:` block should be identical (same Foundry project) but `model.deployment_name` should differ as planned.

---

## Step 2 — Add sibling-invocation glue to the orchestrator

The orchestrator's `main.py` needs three things the template doesn't generate:
1. A `_DATA_BUFFER` module-level dict
2. A `_invoke_sibling(name, payload)` helper (HTTPS POST + retry + response extraction)
3. Three `@tool` wrappers — one per sibling — that call the helper, stash full data in the buffer, and return only a summary handle to the LLM

Open `agents/feedback-orchestrator/main.py` and add:

```python
import json
import os
import time
from typing import Any
import httpx
from azure.identity import DefaultAzureCredential
from agent_framework import tool

# ── Sub-agent registry ─────────────────────────────────────────────────────
# Model name MUST exactly match each sub-agent's configured model. Foundry's
# Responses API requires the model field; sending a different model 400s.
SUBAGENT_MODELS = {
    "feedback-harvester":  "gpt-4.1-nano",
    "feedback-sentiment":  "gpt-4.1-mini",
    "feedback-narrator":   "gpt-4.1-mini",
}

PROJECT_ENDPOINT = os.environ["FOUNDRY_PROJECT_ENDPOINT"]
_credential = DefaultAzureCredential()

# ── Data buffer ────────────────────────────────────────────────────────────
# WHY: orchestrator LLM serializes any tool argument token-by-token. For 25+
# records (~20KB) that's 40-60s of pure output time, plus ~50KB hits Foundry's
# server_error ceiling. The buffer keeps the full data out of the LLM context;
# we hand the LLM only a small summary handle.
_DATA_BUFFER: dict[str, Any] = {}


def _invoke_sibling(name: str, query: str) -> dict[str, Any]:
    """POST to a sibling agent's Responses endpoint with retry + extraction."""
    url = (
        f"{PROJECT_ENDPOINT}/agents/{name}"
        f"/endpoint/protocols/openai/responses?api-version=v1"
    )
    token = _credential.get_token("https://ai.azure.com/.default").token
    headers = {
        "Authorization": f"Bearer {token}",
        "Foundry-Features": "HostedAgents=V1Preview",
        "Content-Type": "application/json",
    }
    body = {
        "model": SUBAGENT_MODELS[name],
        "input": [{"role": "user", "content": query}],
    }

    # 5 attempts, exponential backoff: 2s, 4s, 8s, 8s.
    backoffs = [2, 4, 8, 8]
    last_err = None
    for attempt in range(5):
        try:
            with httpx.Client(timeout=180.0) as client:
                r = client.post(url, json=body, headers=headers)
            if r.status_code in (408, 429) or 500 <= r.status_code < 600:
                last_err = f"HTTP {r.status_code}: {r.text[:200]}"
            else:
                r.raise_for_status()
                return _extract_text(r.json())
        except (httpx.ConnectError, httpx.ReadTimeout) as e:
            last_err = str(e)
        if attempt < 4:
            time.sleep(backoffs[attempt])
    raise RuntimeError(f"sibling {name} failed after 5 attempts: {last_err}")


def _extract_text(resp: dict[str, Any]) -> dict[str, Any]:
    """Three-tier extraction. Always prefer function_call_output for fidelity."""
    # Tier 3 first — sub-agents using @tool return raw data here.
    for item in reversed(resp.get("output", [])):
        if item.get("type") == "function_call_output":
            raw = item.get("output", "")
            return {"text": _strip_fences(raw)}
    # Tier 2 — message content blocks
    for item in resp.get("output", []):
        if item.get("type") == "message":
            for block in item.get("content", []):
                if block.get("type") == "output_text":
                    return {"text": _strip_fences(block.get("text", ""))}
    # Tier 1 — shortcut
    if "output_text" in resp:
        return {"text": _strip_fences(resp["output_text"])}
    raise RuntimeError(f"could not extract text from response: {list(resp.keys())}")


def _strip_fences(s: str) -> str:
    s = s.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[1] if "\n" in s else s
        if s.endswith("```"):
            s = s.rsplit("```", 1)[0]
    return s.strip()


# ── Tool wrappers — these are what the orchestrator LLM sees ───────────────
@tool(approval_mode="never_require")
def invoke_harvester(query: str) -> str:
    """Pull customer feedback rows for the given query. Returns count only."""
    result = _invoke_sibling("feedback-harvester", query)
    _DATA_BUFFER["harvest_records"] = result["text"]   # full data — no LLM
    try:
        records = json.loads(result["text"])
        count = len(records) if isinstance(records, list) else 1
    except json.JSONDecodeError:
        count = 0
    return json.dumps({"status": "success", "count": count})

@tool(approval_mode="never_require")
def invoke_sentiment() -> str:
    """Score sentiment of harvested records. Pulls full data from buffer."""
    full_data = _DATA_BUFFER.get("harvest_records")
    if not full_data:
        return json.dumps({"status": "error", "reason": "call invoke_harvester first"})
    result = _invoke_sibling("feedback-sentiment", full_data)
    _DATA_BUFFER["scored_records"] = result["text"]    # full data — no LLM
    return json.dumps({"status": "success"})

@tool(approval_mode="never_require")
def invoke_narrator() -> str:
    """Generate the executive summary from scored records. Returns full text."""
    full_data = _DATA_BUFFER.get("scored_records")
    if not full_data:
        return json.dumps({"status": "error", "reason": "call invoke_sentiment first"})
    result = _invoke_sibling("feedback-narrator", full_data)
    return result["text"]   # narrator output IS the final answer — return as-is
```

Two non-obvious bits:

- **`invoke_sentiment` and `invoke_narrator` take no arguments.** That's the whole point of the buffer — the LLM doesn't see or pass the data, it just orders the calls.
- **Strip ```json fences in `_strip_fences`.** Sub-agents using raw-JSON instructions sometimes wrap output in fenced blocks despite the directive; defense-in-depth.

Wire the three `@tool` functions into the agent constructor in `main.py` (the template's `tools=[]` list).

---

## Step 3 — Wire each sibling's contract

Each sibling needs three things settled before deploy: its `tools.py` (only harvester has one), its `instructions` (the LLM's contract), and a Dockerfile tweak (only harvester, to bake in the fixture).

### 3a — Harvester: `tools.py` reading the fixture

Create `agents/feedback-harvester/tools.py`:

```python
import json
import os
from agent_framework import tool

# WHERE THE DATA COMES FROM. For this recipe it's a baked-in fixture; in
# production replace this with an MCP call to your CRM/support system, an
# AI Search query, or a Fabric notebook read. The CONTRACT the orchestrator
# expects is: return a JSON array of records, each with id/timestamp/
# customer/channel/text. Keep that shape stable and nothing downstream breaks.
FIXTURE_PATH = os.environ.get("FEEDBACK_FIXTURE_PATH", "/app/fixture/feedback.json")


@tool(approval_mode="never_require")
def fetch_feedback(window_days: int = 7) -> str:
    """Return raw JSON feedback records from the past N days.

    Args:
        window_days: filter to records within this many days (default 7).
            Fixture timestamps are recent; in production this maps to your
            data source's date filter.
    """
    with open(FIXTURE_PATH) as f:
        records = json.load(f)
    # Fixture is small enough that we just return all of it; in production
    # apply window_days against record["timestamp"] here.
    return json.dumps(records)
```

Add the fixture into the harvester's image — append to `agents/feedback-harvester/Dockerfile`:

```Dockerfile
COPY fixture/ /app/fixture/
```

Wire `fetch_feedback` into the harvester's agent constructor in `main.py` (the template's `tools=[]` list).

> **🔄 Production swap point.** When you replace the fixture with a real source, only this file changes. The function name (`fetch_feedback`), its signature, and its return shape stay the same — that's the contract the orchestrator binds against. Examples:
> - **MCP tool**: `result = await client.call_tool("crm.list_feedback", {"window_days": window_days})` → `return json.dumps(result["records"])`
> - **AI Search**: query a `feedback-index` with `window_days` → JSON-serialise the hits
> - **Fabric**: notebookutils → Delta table read → `df.to_json(orient="records")`
> See [foundry-knowledge/decision-tree.md](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-knowledge/decision-tree.md) for how to pick which one.

### 3b — Harvester: instructions

Edit `agents/feedback-harvester/agent.yaml`, replace the `instructions` field:

```yaml
instructions: |
  You are a feedback harvester. When asked to analyse feedback for a window
  (e.g. "last week"), call the `fetch_feedback` tool with the appropriate
  `window_days` integer and return its output VERBATIM.

  Return raw JSON records only. Do not wrap in markdown. Do not add prose.
  Do not summarise. The orchestrator needs the full record array.
```

### 3c — Sentiment: instructions (no tools)

Sentiment has no `tools.py`. The LLM's instructions ARE the contract. Edit `agents/feedback-sentiment/agent.yaml`:

```yaml
instructions: |
  You will receive a JSON array of feedback records. Each record has fields:
  id, timestamp, customer, channel, text.

  For each input record, emit ONE output record with these exact fields:
    - id        (copy from input — used by downstream to re-join)
    - sentiment (one of: "positive", "negative", "neutral")
    - rationale (a single short sentence — max 12 words — explaining why)

  Return a raw JSON array of these output records, same order and length as
  the input. Do not wrap in markdown. Do not add prose. Do not explain.
  If you receive an empty array, return `[]`.
```

### 3d — Narrator: instructions (no tools)

Edit `agents/feedback-narrator/agent.yaml`:

```yaml
instructions: |
  You will receive a JSON array of feedback records. Each record has fields:
  id, sentiment, rationale (the scored output from the sentiment sibling).

  Write an executive summary (under 250 words) in markdown with these
  sections, in this order:
    1. **TL;DR** — one sentence
    2. **Sentiment breakdown** — counts and percentages per sentiment
    3. **Top themes** — 3 to 5 bullets, grouping rationales by theme
    4. **What to act on this week** — 2 to 3 specific bullets

  Return ONLY the markdown. No JSON, no preamble, no closing notes.
```

### 3e — Defensive input unwrapping (sentiment + narrator)

Sub-agents might receive their input wrapped in a single-element object envelope depending on how the orchestrator's tool wrapper hands off the buffer contents. The instructions above tell the LLM to expect "a JSON array" — to make that robust, add this one-liner at the top of each sibling's `instructions` BEFORE the per-record contract:

```
If the input looks like {"records": [...]} or {"rows": [...]} or {"enriched_records": [...]}, treat the inner array as your input.
```

This is the LLM-side counterpart to the unwrap helper documented in [foundry-multi-agent/SKILL.md § Sub-Agent Contracts](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-multi-agent/SKILL.md). For sub-agents without `@tool` functions, the only place to enforce the contract is the instructions text — the LLM IS the parser.

✅ **Checkpoint.** Four agents, each with the right surface:

| Agent | `tools.py`? | Instructions emit | Image content beyond template |
|---|---|---|---|
| feedback-orchestrator | Yes — 3 sibling-call wrappers (Step 2) | Markdown final answer | — |
| feedback-harvester | Yes — `fetch_feedback` reading fixture | Raw JSON array | `fixture/feedback.json` copied via Dockerfile |
| feedback-sentiment | No | Raw JSON array (id + sentiment + rationale) | — |
| feedback-narrator | No | Markdown executive summary | — |

### 3f — Smoke-test the harvester locally (60 seconds)

Before paying for any deploys, confirm the harvester's tool works end-to-end on your laptop:

```bash
cd agents/feedback-harvester
FEEDBACK_FIXTURE_PATH=fixture/feedback.json python -c "
from tools import fetch_feedback
out = fetch_feedback()
import json
records = json.loads(out)
print(f'OK — {len(records)} records, first id: {records[0][\"id\"]}, last id: {records[-1][\"id\"]}')
"
# Expected: OK — 30 records, first id: fb-001, last id: fb-030
```

If you see `FileNotFoundError`, your fixture path is wrong — revisit Step 0. If you see `JSONDecodeError`, the fixture file got mangled (probably during copy/paste in Step 0) — re-copy from `.agents/skills/foundry-agent-playbook/fixtures/feedback-fixture.json`.

---

## Step 4 — Deploy all four agents (`/prepare-deploy` × 4 → `azd up`)

Each agent has its own `azd up` cycle. Sub-agents must exist BEFORE the orchestrator can call them — deploy order matters:

```bash
# Sub-agents first — they need to exist as endpoints
/prepare-deploy agent_path=agents/feedback-harvester
azd up

/prepare-deploy agent_path=agents/feedback-sentiment
azd up

/prepare-deploy agent_path=agents/feedback-narrator
azd up

# Orchestrator last — its env vars need the sub-agent endpoints to validate
/prepare-deploy agent_path=agents/feedback-orchestrator
azd up
```

For each `/prepare-deploy` you'll see the same Track H gates as recipe 01. The orchestrator is the only one that has the `httpx` import — make sure its `requirements.txt` has `httpx>=0.27`.

✅ **Checkpoint.** `azd ai agent show` returns `status: active` for all four. Capture each agent's endpoint URL — you'll need them for Step 7's KQL.

---

## Step 5 — RBAC and identity per sibling (`/configure-rbac` × 4)

Every agent gets its own Entra Agent ID and its own per-agent SP. **The orchestrator does NOT inherit sub-agent grants.** What the orchestrator's SP needs is the right to invoke other agents in the same project, which is conferred by the project's runtime roles (already granted by `/configure-rbac` Phase 2 — `Azure AI User` on the project).

Run `/configure-rbac` for each:

```bash
/configure-rbac agent_path=agents/feedback-harvester  agent_name=feedback-harvester
/configure-rbac agent_path=agents/feedback-sentiment  agent_name=feedback-sentiment
/configure-rbac agent_path=agents/feedback-narrator   agent_name=feedback-narrator
/configure-rbac agent_path=agents/feedback-orchestrator agent_name=feedback-orchestrator
```

For each agent's `agent-status.json`, `rbac.phases_completed` should show `["phase1_image_pull", "phase2_runtime"]`.

> Wait 5–15 minutes for RBAC propagation. Especially important here — orchestrator → sibling calls fail with `401 InvalidAuthenticationToken` if propagation hasn't completed.

If a sibling has its own knowledge / data source (e.g. harvester reads from AI Search), that source's RBAC must be granted to the **harvester's** SP — not the orchestrator's. See [foundry-knowledge/scripts/verify-source-rbac.sh](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-knowledge/scripts/verify-source-rbac.sh).

✅ **Checkpoint.** Every agent has its own `agent-status.json` with `identities.agent_principal_id` populated and `rbac.phases_completed: 2`. Per-source RBAC (if any) attached to the correct sibling.

---

## Step 6 — Verify the pipeline end-to-end (`/verify-agent`)

Verify the orchestrator first — it transitively exercises every sibling:

```bash
/verify-agent agent_name=feedback-orchestrator \
              test_query="Analyze last week's product feedback" \
              agent_path=agents/feedback-orchestrator
```

You should see, in order, in the trace timeline:
1. orchestrator span: `gen_ai.tool.name = "invoke_harvester"` — duration ~30s
2. orchestrator span: `gen_ai.tool.name = "invoke_sentiment"` — duration ~120s
3. orchestrator span: `gen_ai.tool.name = "invoke_narrator"` — duration ~90s
4. orchestrator final response: the narrator's markdown summary

Now also verify each sibling independently to catch sibling-only regressions — use these concrete test queries (the synthetic fixture lets you predict the shape of the answer):

```bash
# Harvester — should return all 30 records from the fixture
/verify-agent agent_name=feedback-harvester \
              test_query="Fetch feedback for the last 7 days" \
              agent_path=agents/feedback-harvester

# Sentiment — pass it 2 records and check it classifies them right
/verify-agent agent_name=feedback-sentiment \
              test_query='[{"id":"fb-001","timestamp":"2026-05-14T09:23:00Z","customer":"anon-c0142","channel":"support_ticket","text":"Loved the new export-to-CSV feature — saved me hours this week."},{"id":"fb-002","timestamp":"2026-05-14T10:11:00Z","customer":"anon-c0301","channel":"app_review","text":"Export timed out on the 500K-row report twice in a row today."}]' \
              agent_path=agents/feedback-sentiment

# Narrator — pass it pre-scored records and check the markdown
/verify-agent agent_name=feedback-narrator \
              test_query='[{"id":"fb-001","sentiment":"positive","rationale":"User explicitly praises CSV export"},{"id":"fb-002","sentiment":"negative","rationale":"Reports repeated export timeouts"}]' \
              agent_path=agents/feedback-narrator
```

**What "pass" looks like, per sibling:**

Harvester response (raw — the orchestrator's `_extract_text` strips fences):
```json
[{"id":"fb-001","timestamp":"2026-05-14T09:23:00Z","customer":"anon-c0142","channel":"support_ticket","text":"Loved the new export-to-CSV feature — saved me hours this week."}, ...30 entries...]
```

Sentiment response (one output record per input, same order):
```json
[
  {"id":"fb-001","sentiment":"positive","rationale":"User explicitly praises CSV export feature"},
  {"id":"fb-002","sentiment":"negative","rationale":"Reports repeated export timeouts on large reports"}
]
```

Narrator response (markdown — exact wording will vary, structure should match):
```markdown
**TL;DR** — Sentiment is mixed, with strong export-tool praise offset by reliability complaints.

**Sentiment breakdown**
- Positive: 1 (50%)
- Negative: 1 (50%)

**Top themes**
- CSV export drives positive reactions
- Export reliability on large reports is a pain point

**What to act on this week**
- Investigate 500K-row export timeout (fb-002)
- Capture the export-praise message for marketing
```

If harvester returns `[]` → fixture path wrong inside the container (re-check Step 3a Dockerfile + Step 0 file copy).
If sentiment returns text/markdown instead of JSON → instructions weren't picked up; re-deploy.
If narrator returns JSON instead of markdown → same root cause (cached old instructions); re-deploy.

✅ **Checkpoint.** Each sibling's `verify` block has `last_run_status: pass`. Orchestrator final response is a markdown executive summary covering the 30-record fixture. Across the 30 records you should see roughly 12 positive / 10 negative / 8 neutral in the sentiment breakdown — confirms the LLM is actually reading the data, not hallucinating.

### When to switch to SSE streaming

Add a 4th sub-agent (priority scorer, reasoning model, `reasoning_effort: high`, ~180s). Total pipeline now ~4.5 minutes, comfortably > the 120s SSE-default threshold.

In the orchestrator's `_invoke_sibling`, switch to streaming on calls expected to exceed 120s:

```python
def _invoke_sibling_stream(name: str, query: str) -> dict[str, Any]:
    """Same as _invoke_sibling but uses SSE for >120s pipelines."""
    body["stream"] = True
    headers["Accept"] = "text/event-stream"

    state = {"status": "STARTING", "buffer": [], "final_text": None}
    with httpx.Client(timeout=httpx.Timeout(connect=10.0, read=600.0, write=10.0, pool=10.0)) as client:
        with client.stream("POST", url, json=body, headers=headers) as r:
            saw_done = False
            for line in r.iter_lines():
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                if payload == "[DONE]":
                    saw_done = True
                    break
                event = json.loads(payload)
                _apply_sse_event(event, state)
    if not saw_done:
        raise RuntimeError(f"SSE stream closed without [DONE] for {name}")
    return {"text": state["final_text"]}
```

The full `_apply_sse_event` state machine (event types: `output_item.added`, `output_item.done`, `response.completed`) is in [foundry-multi-agent/SKILL.md § SSE Streaming](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-multi-agent/SKILL.md). A single token (~1h validity) covers a 9-minute pipeline.

✅ **Checkpoint.** Pipeline with priority scorer added completes end-to-end without `httpx.ReadTimeout`. The orchestrator log shows SSE events arriving every few seconds during the 180s priority phase.

---

## Step 7 — Per-sibling OTel verification

The whole point of decomposing is to see **which sibling** is the slow one. Run this KQL to get a per-sibling latency view:

```kql
let agents = dynamic([
  "feedback-orchestrator","feedback-harvester","feedback-sentiment",
  "feedback-narrator","feedback-priority"
]);
dependencies
| where cloud_RoleName in (agents)
| where name in ("execute_tool", "invoke_agent", "chat")
| extend tool = tostring(customDimensions["gen_ai.tool.name"])
| summarize
    p50 = percentile(duration, 50),
    p95 = percentile(duration, 95),
    n   = count()
  by cloud_RoleName, name, tool
| order by p95 desc
```

Expect to see:
- One row per sibling × span-name combination
- `feedback-orchestrator` has rows for each `invoke_*` tool call (those are the sibling-call spans)
- Each sibling has its own `chat` rows (the LLM call inside that sibling)

If a sibling is missing → it never received a call (orchestrator routing bug, or that path wasn't exercised).
If `tool` is empty on orchestrator rows → `ENABLE_INSTRUMENTATION=true` is missing on the orchestrator's env vars.

To track buffer cache hits (so you can prove the LLM-bypass is working), add a custom span in `invoke_sentiment`:

```python
from opentelemetry import trace
_tracer = trace.get_tracer(__name__)

@tool(approval_mode="never_require")
def invoke_sentiment() -> str:
    with _tracer.start_as_current_span("data_buffer.read") as span:
        full_data = _DATA_BUFFER.get("harvest_records")
        span.set_attribute("data_buffer.key", "harvest_records")
        span.set_attribute("data_buffer.hit", full_data is not None)
        span.set_attribute("data_buffer.size_bytes", len(full_data or ""))
    # ... rest as before
```

Then KQL:

```kql
dependencies
| where cloud_RoleName == "feedback-orchestrator"
| where name == "data_buffer.read"
| extend hit  = tobool(customDimensions["data_buffer.hit"])
| extend size = toint(customDimensions["data_buffer.size_bytes"])
| summarize hits=countif(hit), miss=countif(not hit), avg_size=avg(size)
```

✅ **Checkpoint.** P95 latency view shows the slowest sibling clearly. Buffer-hit count > 0 (LLM-bypass is working). Buffer-miss count = 0 (no orchestration races).

---

## Step 8 — Per-sibling continuous eval (`/setup-evals` × 4)

Orchestrator quality is independent of sibling quality. A great harvester + great sentiment + bad narrator = bad final output, but the orchestrator's eval would still score "tool_call_accuracy: pass." You need separate eval rules per agent.

```bash
/setup-evals agent_name=feedback-harvester  agent_path=agents/feedback-harvester
/setup-evals agent_name=feedback-sentiment  agent_path=agents/feedback-sentiment
/setup-evals agent_name=feedback-narrator   agent_path=agents/feedback-narrator
/setup-evals agent_name=feedback-orchestrator agent_path=agents/feedback-orchestrator
```

Tailor the evaluator selection per role:
- **Orchestrator**: `tool_call_accuracy` (did it call siblings in the right order?), `task_adherence`
- **Harvester**: `tool_call_accuracy` only (did the data-source MCP call return the right rows?)
- **Sentiment**: `task_adherence` (did it actually classify each record?)
- **Narrator**: `relevance`, `coherence` (is the summary actually well-written?)

`/setup-evals` will dry-run each rule before creating it — review the evaluator list per agent.

✅ **Checkpoint.** Four eval rules visible in the Foundry portal Monitor tab, one per agent. Send 3-5 pipeline runs through; within 10 minutes each rule has scores.

---

## Step 9 — Drift baseline across all four agents

Each agent has its own `agent-capabilities.yaml` and its own `drift.capability_hash_at_rbac` baseline. A change to any one of them is drift on that agent only — siblings don't cascade.

For ongoing operation, schedule a per-agent drift check (e.g. weekly):

```bash
for agent in feedback-orchestrator feedback-harvester feedback-sentiment feedback-narrator; do
  python .agents/skills/foundry-deploy/scripts/agent_status.py drift \
    --agent-path "agents/$agent"
done
```

Each call exits 0 (clean) or 1 (drift detected with hash diff). Wire into your CI to fail PRs that touch a manifest without re-running `/configure-rbac`.

✅ **Checkpoint.** All four `agent-status.json` files have `drift.capability_hash_at_rbac` populated. Drift script exits 0 for each.

---

## Recap — what you proved

| Concern | Evidence |
|---|---|
| Pipeline shape | One orchestrator + N siblings, deployed independently |
| Data-buffer LLM bypass | `data_buffer.read` spans show `hit: true`, no 50KB+ payloads in orchestrator tool args |
| SSE streaming for >120s | Priority sibling completes via streamed events; no `httpx.ReadTimeout` |
| Per-sibling identity + RBAC | Each agent's `identities.agent_principal_id` is unique; per-source RBAC attached to the correct sibling |
| Per-sibling observability | KQL summarises P50/P95 latency by sibling; you can identify the bottleneck |
| Per-sibling eval | Four separate eval rules with role-appropriate evaluators |
| Drift coverage | All four manifests have a `capability_hash_at_rbac` baseline |

## Operational notes — multi-agent in production

These are decisions this recipe deliberately defers; flag them in your runbook:

- **Cost.** Four hosted agents = four containers running. Right-size the sub-agent SKUs (nano + mini are much cheaper than chat / reasoning); the orchestrator is the cheapest because it does almost no LLM work — most of its time is spent waiting on siblings.
- **SLO target shape.** End-to-end P95 ≠ sum of per-sibling P95 (siblings are sequential, not concurrent here). Define separate SLOs for orchestrator P95 and per-sibling P95. See [foundry-prod-readiness/SKILL.md](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-prod-readiness/SKILL.md).
- **Sibling versioning.** Each sub-agent has its own version lifecycle. Updating sentiment's instructions doesn't redeploy the orchestrator. But: schema-incompatible changes (e.g. sentiment now returns a different field name) silently break the pipeline; cover with a contract test.
- **Pattern 2b — Parallel fan-out.** If harvester and a metadata enricher could run concurrently, the orchestrator LLM can call multiple `invoke_*` tools in one turn. The buffer pattern still applies; the contract is no harder.
- **Pattern 2c — Hybrid.** Mixing hosted siblings with prompt sub-agents is supported — but watch for the model-mismatch trap (`SUBAGENT_MODELS` mapping must match what each sub-agent is actually deployed with). Documented in [foundry-patterns/SKILL.md § 2c](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-patterns/SKILL.md).
- **Pattern 2d — Peer-to-peer A2A.** No central orchestrator — each agent owns its routing. Out of scope here; that's a different recipe (not yet authored).

## Cleanup

```bash
# Each agent has its own azd env
for agent in feedback-orchestrator feedback-harvester feedback-sentiment feedback-narrator; do
  ( cd "agents/$agent" && azd down --purge )
done

# Eval rules — re-run /setup-evals with --enabled false for each (no separate delete script today)
```

## Where to go next

- Need DLP / sensitivity-label enforcement at the sibling boundary? See [03-knowledge-with-purview.md](03-knowledge-with-purview.md).
- One of the siblings is APIM-fronted? See [05-apim-fronted-mcp.md](05-apim-fronted-mcp.md) — applies per-sibling, not just to single agents.
- Need scheduled (regression-set) eval for the whole pipeline? See [04-ai-search-with-scheduled-eval.md](04-ai-search-with-scheduled-eval.md) and run it against the orchestrator endpoint.
- Decomposing further into A2A peer-to-peer (Pattern 2d)? Not covered by a recipe today; see [foundry-patterns/SKILL.md § 2d](https://github.com/sathik11/foundry-agent-skillpack/blob/main/foundry-agent-skillpack/.apm/skills/foundry-patterns/SKILL.md) for the shape.
