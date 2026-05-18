# Layer 1.5 — Purview DLP Middleware

> **The unique gap this layer fills.** Microsoft Purview AI Hub gives you **audit + discovery + classification** for Foundry hosted agents once the toggle is on (see [foundry-purview/SKILL.md](../foundry-purview/SKILL.md)). What it does **not** give you natively is **enforcement** — actual block / warn / audit decisions on agent prompts and responses based on detected SITs and sensitivity labels.
>
> M365 Copilot and Copilot Studio agents get DLP enforcement built into the runtime. **Foundry hosted agents don't.** This middleware closes that gap for any agent that needs it.
>
> Validity: 2026-05-14. Surface is preview-adjacent — re-verify against [Purview DSPM for AI](https://learn.microsoft.com/purview/ai-microsoft-purview) docs on a regular cadence.

## Where this sits in the guardrail stack

| Layer | Latency | Provider | What it catches |
|---|---|---|---|
| 1 — Vendored middleware | sub-ms | Your code | Length, jailbreak regex, XPIA tokens |
| **1.5 — Purview DLP middleware** | ~150–500ms | Purview classification API | **PII, PCI, PHI, custom SITs, sensitivity-labelled content** |
| 2 — Azure Content Safety | ~150ms | Azure managed | Violence / Hate / Sexual / SelfHarm severity |
| 3 — Continuous eval + cloud red-team | hourly / nightly | Foundry | Quality + adversarial drift |

Layer 1.5 runs **after** Layer 1 (cheap text rules first) and **before** Layer 2 (CS doesn't classify SITs). All three are independent — pick the layers your agent needs.

## When to use this layer

- Agent processes user prompts that may contain **PII / PCI / PHI** (customer support, healthcare, finance).
- Agent responses are derived from **labelled documents** (SharePoint, OneLake) where the label needs to flow through to the response.
- Compliance / regulatory mandate (GDPR, HIPAA, PCI-DSS) requires per-prompt classification + audit trail.
- You want **block / warn enforcement** of detected sensitive content, not just retrospective audit.

## When NOT to use this layer

- Agent operates on already-public content (no SITs to classify).
- Latency budget is tight (< 200ms total for guardrails).
- You're prototyping — start with audit-only, opt into enforcement later.
- M365-Copilot-equivalent agent — those get DLP for free via M365 plumbing; this middleware is redundant.

## What the middleware does at runtime

For each turn, the middleware:

1. **Extracts text** — user prompt on input; agent response (and optionally tool inputs/outputs) on output.
2. **Classifies via Purview** — calls the Purview Information Protection / Compliance classification API; gets back detected SITs and matched sensitivity labels.
3. **Looks up policies** — matches against the policy IDs declared in `agent-capabilities.yaml guardrails.purview_dlp.policies`.
4. **Decides** — based on `enforcement_mode`:
   - `audit_only` → emit OTel span + `AIPolicyEvaluated` event; allow the request.
   - `warn` → annotate the response with a warning; emit event; allow the request.
   - `block` → short-circuit; refuse the request; emit `AIPolicyBlocked` event.
5. **Stamps OTel** — `guardrail.purview_dlp.*` attributes on the agent span (sits, labels, policy_id, decision).

## Honest preview limitations (read before enabling `block`)

These are real and tracked under TD-4 in `TECHNICAL_DEBT.md`:

1. **Token surface.** The Purview Compliance / Information Protection API may require a Compliance-Admin-tier token, which an agent container shouldn't carry. The middleware tries `DefaultAzureCredential` first; if your tenant requires a service-principal with elevated rights, you accept the risk of that secret living in agent env vars. **For these reasons, `enforcement_mode: block` requires explicit `AGREE_PURVIEW_DLP_PREVIEW=1` env var to start the agent.**
2. **Label propagation.** Sensitivity labels follow data automatically *only* when the source surfaces them via OBO (M365 Copilot path). For Foundry hosted with `acl_passthrough: false` on knowledge sources, labels in the source document may NOT appear in the classification response — the middleware can only act on what it sees in the prompt/response payload itself.
3. **Latency.** Two extra API calls per turn (input + output). Budget 300–600ms p95 added.
4. **Cost.** Per-classification cost is small but non-zero. With 100 invocations/hour × 2 calls × $0.0001/call ≈ $0.50/agent/day baseline; multiply by your traffic.
5. **No retroactive enforcement.** This middleware acts at request time; pre-existing audit events from before enabling it stay unaffected.

If any of (1) or (2) are blockers for your tenant, run in `audit_only` mode permanently and rely on Purview-portal-side incident response.

## Schema (in `agent-capabilities.yaml`)

```yaml
guardrails:
  enabled: true
  layers: [middleware, content_safety, purview_dlp]   # ← order matters; 1.5 between 1 and 2
  middleware_mode: entry
  content_safety:
    connection_name: cs-prod
    severity_threshold: 4
  purview_dlp:                                         # ← NEW block
    enabled: true
    enforcement_mode: audit_only                       # audit_only | warn | block
    policies:                                          # Purview-side policy IDs the middleware consults
      - dlp-pii-strict
      - dlp-pci-block
    classify_tool_results: false                       # set true to also classify tool outputs
    classify_agent_response: true                      # set false to only classify user input
    sit_types_to_check: []                             # optional explicit list; empty = all configured in policies
    refusal_text: "Your request contained sensitive information that cannot be processed by this agent."
```

## Required RBAC (per-agent SP)

| Role | Scope | Why |
|---|---|---|
| `Purview Information Protection Reader` (or custom equivalent) | Purview tenant | To call `/classify` |
| `AIP Service Reader` | Tenant | Label cache resolution (when sensitivity labels are in scope) |

Run [scripts/grant-purview-dlp-access.sh](scripts/grant-purview-dlp-access.sh) post-deploy. **Both roles are tenant-scoped** — your dev caller often won't have rights to grant them; the script emits a runbook to the tenant admin in that case (see [foundry-roles/runbook-format.md](../foundry-roles/runbook-format.md)).

## Wire it (in `main.py`)

```python
from guardrails import GuardrailAgentMiddleware
from purview_dlp_middleware import PurviewDLPMiddleware

agent = Agent(
    client=client,
    instructions=INSTRUCTIONS,
    tools=TOOLS,
    middleware=[
        GuardrailAgentMiddleware(agent_name="<name>", mode="entry"),     # Layer 1
        PurviewDLPMiddleware(                                            # Layer 1.5
            agent_name="<name>",
            enforcement_mode="audit_only",                               # start here
            policies=["dlp-pii-strict"],
            classify_agent_response=True,
            classify_tool_results=False,
        ),
        # Layer 2 (Content Safety) is invoked from inside Layer 1 today;
        # if you split it into its own middleware, add it here.
    ],
)
```

The middleware module is shipped at [scripts/purview_dlp_middleware.py](scripts/purview_dlp_middleware.py). **Each agent vendors its own copy** — same convention as `guardrails.py`.

## Gate matrix (Phase A / B / C)

### Phase A — preflight (`/prepare-deploy`)

When `guardrails.layers` includes `purview_dlp`:
1. `purview.enabled: true` must also be declared (DLP without audit makes no sense — confirm with user otherwise).
2. `purview_dlp.policies[]` is non-empty.
3. `purview_dlp_middleware.py` is vendored into the agent folder.
4. `main.py` imports and uses `PurviewDLPMiddleware`.
5. If `enforcement_mode: block` — print the preview-only warning callout and require `AGREE_PURVIEW_DLP_PREVIEW=1` env var to be set on the agent version.
6. Caller has at least `Reader` on the Purview account (to verify policy IDs exist — best-effort; some tenants restrict policy enumeration).

### Phase B — post-deploy grants (`/configure-rbac`)

```bash
.agents/skills/foundry-guardrails/scripts/grant-purview-dlp-access.sh <agent_name>
```

The script:
1. Resolves the per-agent SP via `azd ai agent show`.
2. Attempts the two role grants (Purview Information Protection Reader + AIP Service Reader).
3. If the caller lacks `Privileged Role Administrator` (almost always the case for devs), emits a runbook block — paste-ready for the tenant admin.

### Phase C — verify (`/verify-agent`)

1. **Smoke**: send a deliberately-PII-bearing input (e.g., `"My SSN is 123-45-6789"` for US tenants). Expect:
   - `audit_only` mode: response goes through; OTel span shows `guardrail.purview_dlp.decision: audit_only`, `guardrail.purview_dlp.sits: ["U.S. Social Security Number"]`.
   - `warn` mode: response includes a warning preface; same OTel + an `AIPolicyEvaluated` event in Purview Audit.
   - `block` mode: refusal text returned; OTel span shows `decision: block`; `AIPolicyBlocked` event in Purview Audit within ~30 minutes.
2. **KQL**:
   ```kql
   dependencies
   | where cloud_RoleName == "<agent_name>"
   | where name startswith "guardrail.purview_dlp"
   | project timestamp, name, customDimensions["guardrail.purview_dlp.decision"], customDimensions["guardrail.purview_dlp.sits"]
   | order by timestamp desc | take 20
   ```
3. **Purview portal**: DSPM → Activity Explorer → filter by agent name; expect classification events and (if enforcement) `AIPolicyBlocked`/`AIPolicyEvaluated` rows.

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| Every request returns "audit_only" but Purview shows nothing | Per-agent SP lacks Purview reader role; middleware fails open | Phase B grant; wait propagation |
| `block` mode never blocks | `policies[]` doesn't match real Purview policy IDs | List policies in Purview portal; copy IDs verbatim |
| 401 from Purview API | Token surface mismatch (TD-4 caveat) | Check `DefaultAzureCredential` chain; consider service-principal with elevated rights (accept risk) |
| Latency spike on every turn | Tool-result classification on noisy tools | Set `classify_tool_results: false`; keep response classification only |
| `block` mode rejects legitimate prompts | Policy too aggressive; SIT false positive | Tune the Purview policy itself; or move to `warn` mode while iterating |

## Cross-skill references

- Purview audit toggle (Layer 0 prerequisite) → [foundry-purview/SKILL.md](../foundry-purview/SKILL.md)
- Layer 1 vendored middleware → [middleware.md](middleware.md)
- Layer 2 Azure Content Safety → [content-safety.md](content-safety.md)
- Layer 3 evals + red-team → [foundry-evals/SKILL.md](../foundry-evals/SKILL.md)
- Tenant-admin runbook format → [foundry-roles/runbook-format.md](../foundry-roles/runbook-format.md)
- TD-4 status → [TECHNICAL_DEBT.md](../../../TECHNICAL_DEBT.md)
