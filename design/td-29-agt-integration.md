# TD-29 — AGT Integration Design (v0.24)

**Status:** Draft for review — design lock pending.
**Author / Spike date:** 2026-05-26.
**Scope:** v0.24 ships TD-29 (AGT Option B integration). TD-28 (cross-OS bake-off) runs as v0.24 research and lands its decision in v0.25 separately.

> **Why this doc exists:** AGT spans 47+ packages across 8+ distinct concerns. Integrating *all* of it would be a mistake. Integrating *none* of it leaves our v0.23.0 positioning verbal-only. This doc proposes a **3-tier model** that picks the smallest useful AGT surface for Foundry hosted agents, declares what we deliberately don't bundle, and gives users a clean opt-in path for everything else.

---

## 1. Spike findings that drive this design

Spike against AGT v3.7.0 + `agent-framework` 1.6.0 in a clean Python 3.12 venv (`/tmp/agt-spike`). Full log in session memory.

| # | Finding | Direct impact |
|---|---|---|
| 1 | Bare `pip install agent-governance-toolkit` ships **only the `agt` CLI** (`agent_compliance` pkg). `govern()` runtime requires `[full]` extra. | Schema must inject `agent-governance-toolkit[full]`, not the bare name. |
| 2 | `[full]` installs **47 packages**: `agent_os_kernel`, `agent_hypervisor`, `agent_sre`, `agentmesh_platform`, `agentmesh-runtime`. ~1-2 MB on disk. | Container cost is non-trivial but acceptable. Tier 2 add-ons can opt out of subsets later. |
| 3 | **`agent_framework` and `agentmesh` coexist cleanly** — both importable in same venv, `govern()` callable after `agent-framework` install, no pydantic/click/pyyaml conflicts. | **Biggest unblock.** AGT works in-process inside Foundry's single-container model. No sidecar needed. |
| 4 | Real `govern()` signature: `govern(fn, policy, agent_id='*', audit=True, on_deny=None, approval_handler=None, advisory=None, conflict_strategy='deny_overrides')`. | `on_deny` callback is our OTel cross-link hook. `approval_handler` is the human-in-the-loop path. |
| 5 | **AGT docs' policy.yaml examples FAIL pydantic validation** against the installed package. Real schema: `condition: <string>` (not dict), `action: allow\|deny\|warn\|require_approval\|log` (not `block/audit`). | `/prepare-deploy` MUST run `agt lint-policy` as a hard gate — relying on docs-style examples will silently break consumers. |

---

## 2. AGT's actual surface — what to integrate vs not

| AGT layer | What it does | Decision | Reason |
|---|---|---|---|
| `agentmesh.governance.govern()` + `agent_os_kernel` | Per-tool-call policy engine | ✅ **Tier 1 (core)** | Foundry has zero equivalent. This is the irreducible value. |
| `agent_compliance` (`agt lint-policy`, `agt verify`, `agt red-team scan` CLIs) | Validation + compliance CLI | ✅ **Tier 1 (lint)** + Tier 2 (red-team) | Lint is mandatory in `/prepare-deploy`. Red-team scan is opt-in for CI. |
| MCP Security Gateway | Tool poisoning, hidden instruction scanning, typosquatting | ✅ **Tier 2 (opt-in)** | Complements our existing APIM-as-MCP-frontdoor pattern. Different layer (content vs network). |
| `agent_sre` | Kill switch, SLO monitoring, chaos | 🟡 **Tier 2 (opt-in)** | Partial overlap with Foundry health probes. Useful for production but operational policy belongs to the user. |
| `agent_hypervisor` | Four privilege rings, sandboxing, commitment anchoring | ❌ **Tier 3 (explicit error)** | Foundry container is already isolated. Layering AGT's hypervisor adds overhead + a second sandbox to validate. |
| `agentmesh_platform` SPIFFE/DID identity | Cross-cloud zero-trust agent identity | ❌ **Tier 3 (explicit error)** | Foundry agents have Entra Agent ID + project/agent/application identity flip. Double-identity model is confusing and harder to audit. |
| `agent_lightning` | RL training governance | ❌ **Tier 3 (explicit error)** | Out of scope — we don't ship RL training. |
| `agent_marketplace`, Dashboard, Antigravity CLI | Plugin marketplace, fleet visibility, separate CLI | ❌ **Not integrated** | Separate products. No skillpack-side wiring is meaningful. |

---

## 3. Proposed schema — new `runtime_governance:` block in `agent-capabilities.yaml`

```yaml
runtime_governance:
  # ── Tier 1: core (when provider is agt) ──────────────────────
  provider: agt | none                              # default 'none' (no AGT)
  policy_file: governance/policy.yaml               # path relative to agent root
  
  fail_mode: deny | warn | require_approval | log   # → policy defaults.action
  audit_sink: otel                                  # v0.24 only emits via OTel
                                                    #   (Merkle log needs writable FS;
                                                    #    Foundry container may be read-only;
                                                    #    revisit in v0.25)
  agent_id_template: "did:foundry:<agent_name>"     # rendered at /prepare-deploy time;
                                                    #   wildcards are explicitly disallowed
  
  # ── Tier 2: opt-in add-ons ────────────────────────────────────
  add_ons:
    mcp_security_gateway: auto | true | false       # 'auto' = enabled when mcp_servers
                                                    #   declared elsewhere in capabilities
    sre_monitoring: false                           # opt-in; /prepare-deploy suggests
                                                    #   if continuous_eval is declared
    redteam_ci: false                               # adds 'agt red-team scan' step to
                                                    #   the existing redteam.yml workflow
  
  # ── Tier 3: explicit errors if user sets these ────────────────
  # hypervisor: true        → /prepare-deploy ERROR with rationale
  # mesh_identity: spiffe   → /prepare-deploy ERROR with rationale
  # lightning: true         → /prepare-deploy ERROR with rationale
```

**Backward compat:** if `runtime_governance:` is absent (every existing manifest today), behavior is identical to `provider: none`. No breaking change.

---

## 4. What each surface changes

| Surface | Concrete change | Effort estimate |
|---|---|---|
| **`agent-capabilities.yaml` schema** | New `runtime_governance:` block. Validator with Tier 3 error path. | S |
| **`foundry-deploy/capabilities-manifest.md`** | Document the new block + tier model + examples. | S |
| **`/prepare-deploy` prompt** | New "AGT gate" step: lint-policy → render agent_id → inject `agent-governance-toolkit[full]` + add_on extras → error on Tier 3 declarations. Capture lint hash in `agent-status.json`. | M |
| **`foundry-deploy/templates/agent-framework/`** | Add `governance/policy.yaml` starter. `main.py` gets commented-out `govern(...)` wrap per declared tool. Uncommented automatically by `/prepare-deploy` when `provider: agt`. | M |
| **`foundry-deploy/templates/langgraph-byo/`** | Same — but with langgraph tool-registration pattern. Requires a Phase 2 sub-spike. | M |
| **`foundry-guardrails/SKILL.md`** | Promote current "Related runtime layer" callout to a real **Layer 0** section. Cross-link this design doc. | S |
| **`/audit-drift` prompt** | Hash declared `policy_file`, compare to deployed image's `policy.yaml`. Flag drift if mismatch. | S |
| **`agent-status.json` schema (v1.3)** | Add `runtime_governance: {provider, policy_sha256, last_lint_pass_at, add_ons_enabled}` block. Additive; no `schema_version` bump (precedent: v1.2 in TD-23). | S |
| **`foundry-agent-playbook/samples/agt-governed-sample/`** | New runnable sample showing Tier 1 + one Tier 2 add-on end-to-end. | M |
| **TD-29 in `TECHNICAL_DEBT.md`** | Replace current spec with the design lock (this doc as appendix). | S |
| **Docs `related-work.md`** | Update integration plan section to point at this design doc + tier model. | S |

---

## 5. Three open design decisions (default + alternatives)

These are explicit so a reviewer can override them later.

### Decision A — Tier 3 enforcement

**Recommendation: error (fail-stop) in `/prepare-deploy`.**

| Option | Rationale |
|---|---|
| ✅ **Error** | Refusing things gracefully is what makes the boundary credible. Warnings get ignored; explicit refusal teaches users what we cover. Mirrors the TD-24 lesson — silent fallbacks (`\|\| echo '[]'`) hide problems. |
| ❌ Warn | Users will silently deploy with hypervisor flags that do nothing, then file bugs against us when AGT's hypervisor behavior surprises them. |
| ❌ Allow + ignore | Worst option — users assume integration is broken. |

### Decision B — `add_ons` defaults

**Recommendation: `mcp_security_gateway: auto`, others `false`.**

| Add-on | Default | Why |
|---|---|---|
| `mcp_security_gateway` | `auto` | Highest-value combo. If the user declared `mcp_servers:` in capabilities, they almost certainly want MCP-call governance. `auto` auto-enables; user can force `false` to opt out. |
| `sre_monitoring` | `false` | Operational policy. Foundry already has health probes. Suggest in `/prepare-deploy` output if `continuous_eval` is declared, but don't auto-enable. |
| `redteam_ci` | `false` | Adds GitHub Actions surface. Belongs to the team's CI hygiene policy, not our default. Suggest in `/setup-evals` flow. |

### Decision C — `agent_id_template`

**Recommendation: fixed as `did:foundry:<agent_name>` for v0.24.**

| Option | Rationale |
|---|---|
| ✅ **Fixed `did:foundry:<agent_name>`** | One less knob. Audit logs have a single recognizable shape. Override added in v0.25 if any user asks. |
| ❌ User-overridable | Premature flexibility. Half the users will set typo-laden values that break audit-trail tooling. |
| ❌ Use raw `agent_name` | Loses the DID-style prefix that AGT's audit tooling assumes (per `did:agentmesh:` examples in their MAF docs). |

---

## 6. Phase plan

| Phase | Status | Work |
|---|---|---|
| **Phase 1 — Spike** | ✅ Done (this turn) | AGT install, govern() probe, policy.yaml schema discovery, coexistence verification. Findings captured in §1. |
| **Phase 2 — Sub-spikes + design lock** | ⏳ Next | (a) Capture AGT's OTel span attribute names by tracing one `govern()` call. (b) Verify `agent-framework`'s `@tool(approval_mode='never_require')` decorator doesn't conflict with `govern()` wrapping. (c) Verify `langgraph-byo` template integration path. (d) Lock the schema (§3) by updating TD-29 in `TECHNICAL_DEBT.md` to reference this doc. |
| **Phase 3 — Implementation** | Blocked on Phase 2 | All §4 surface changes. Land in a series of small PRs, each separately reviewable. |
| **Phase 4 — Validation** | Blocked on Phase 3 | Real agent deployed to `agents-3iq` with `provider: agt` + Tier 1 only. Then with one Tier 2 add-on. Drift report from `/audit-drift`. |
| **v0.24 cut** | Blocked on Phase 4 | All four phases green; TD-29 marked closed in `TECHNICAL_DEBT.md`; docs published. |

---

## 7. Alternatives explicitly considered and rejected

| Alternative | Why rejected |
|---|---|
| **Integrate all of AGT (no tiers)** | Forces SPIFFE/Entra double-identity confusion; layers hypervisor on top of Foundry container; ships AGT features that conflict with Foundry-native equivalents. |
| **Integrate only bare `govern()` (Tier 1 only, no Tier 2)** | Misses MCP Security Gateway (genuine value, low cost), redteam CI (already adjacent to our `redteam.yml`). Future demand will force Tier 2 anyway; better to design it in now. |
| **Document AGT but don't integrate (status quo from v0.23.0 Option A)** | This is what was rejected by user choosing Option 3 (adopt + integrate). v0.23.0 already ships Option A; v0.24 must do more. |
| **Tiered model with magic auto-everything (no explicit `add_ons:` block)** | Hides decisions from users. First time something opts in unexpectedly, trust is lost. |
| **Wait for AGT to GA (v4.0+) before integrating** | TD-29 already says we integrate against a stable AGT minor; v3.7.0 + the Pydantic-validated schema is stable enough for our narrow Tier 1 surface. Tier 2 add-ons can be deferred per add-on if their AGT surface is too unstable. |

---

## 8. Risks and unknowns (tracked for Phase 2)

| Risk | Mitigation |
|---|---|
| `@tool(approval_mode='never_require')` + `govern()` ordering may conflict | Phase 2 sub-spike (b). If conflict, document required ordering in templates. |
| AGT OTel span names may not be stable across versions | Pin AGT minor in `requirements.txt`; treat span names as observable API in `agent-status.json`. |
| Container FS read-only may break AGT internal state | Default `audit_sink: otel` (no disk writes); document for Tier 2 add-ons that need writable temp space. |
| AGT's policy schema may change before v4.0 GA | `agt lint-policy` gate catches schema drift at `/prepare-deploy` time; pin AGT version. |
| `langgraph-byo` template integration path is unknown | Phase 2 sub-spike (c). If hard, ship `provider: agt` for `agent-framework` only in v0.24, langgraph in v0.25. |
| User declares Tier 3 flags expecting them to work | Decision A (error fail-stop) + clear error message pointing to this doc. |

---

## 9. What this doc is NOT

- Not a tutorial — that lives in `foundry-agent-playbook/samples/agt-governed-sample/` (Phase 4).
- Not the consumer-facing positioning — that's `docs/concepts/related-work.md` (already published in v0.23.0).
- Not a final spec — Phase 2 sub-spikes may force refinements to §3.

---

## 10. Reviewer questions to answer

Before Phase 3 implementation starts, the reviewer should explicitly answer:

1. Do you accept the 3-tier model in §2? Specifically: do you agree with the **Tier 3 list** (hypervisor / SPIFFE / lightning explicitly NOT integrated)?
2. Do you accept Decision A (Tier 3 errors, not warnings)?
3. Do you accept Decision B (`mcp_security_gateway: auto`, others `false`)?
4. Do you accept Decision C (fixed `agent_id_template` for v0.24)?
5. Is `audit_sink: otel`-only in v0.24 (no Merkle) acceptable, or do you want Merkle support gated behind a writable-tempdir check?
6. Should `langgraph-byo` template integration block v0.24, or is `agent-framework`-only acceptable for the v0.24 cut?

Answers go in §5 as "DECIDED:" annotations; default recommendations stand if not answered.

---

## 11. Phase 2 sub-spike addendum (2026-05-26)

Three follow-up sub-spikes ran against the same `/tmp/agt-spike` venv after the original spike. **Four substantive findings**, including one that simplifies the design materially.

### Finding 1 — AGT emits OTel spans natively (simplifies the design)

`grep -r "set_attribute" .venv/.../agentmesh/` reveals **6 agentmesh modules instrument with OpenTelemetry**, including a dedicated `agentmesh.governance.otel_observability` module. The real span-attribute namespace is **`agt.*`**, not the `evaluator.agt.*` shape I invented in §3.

Confirmed real attribute names AGT emits (partial list):
- `agt.action`, `agt.agent.id`, `agt.agent_id`, `agt.did`
- `agt.policy.action`, `agt.policy.denials`, `agt.policy.evaluate`, `agt.policy.evaluations`, `agt.policy.latency_ms`
- `agt.approval.approver`, `agt.approval.outcome`, `agt.approval.request`, `agt.approval.requests`
- `agt.audit.append`, `agt.audit_entries`

Tracer names (for OTel SDK setup):
- `agentmesh.governance` (primary)
- `agentmesh.providers.audit`, `agentmesh.providers.capability`, `agentmesh.providers.delegation`
- `agentmesh.server.api_gateway`, `agentmesh.server.policy_server`, `agentmesh.server.trust_engine`

**Design impact (this rewrites part of §3 and §4):**
- ❌ DROP the `on_deny` callback approach for OTel cross-link. We don't need it.
- ✅ ADD: ensure the agent container's OTel SDK collects from the `agentmesh.governance` tracer (default config does this if `azure-monitor-opentelemetry` is set up — already the case in our templates as of v0.18).
- ✅ ADD: document the `agt.*` attribute namespace in our KQL cookbook so operators can query AGT decisions in App Insights.
- ✅ KEEP: `audit_sink: otel` in the schema, but it now means "use AGT's native OTel emission" rather than "we wire a callback."

### Finding 2 — `@tool(approval_mode=...)` + `govern()` ordering — no conflict

`agent_framework.tool` is a decorator factory. `@tool(approval_mode="never_require")(echo)` returns a **`FunctionTool` class instance** (no `__wrapped__` attribute; `__name__` not set). `govern()` accepts the `FunctionTool` as its `fn` parameter and returns a `GovernedCallable` cleanly.

**Design impact:** Templates can write `safe_x = govern(x, policy=...)` directly after `@tool` decoration. No special unwrapping or re-ordering needed.

### Finding 3 — `langgraph-byo` template integration is unblocked

`langgraph` + `langchain_core.tools.tool` install cleanly alongside `agentmesh` (no version conflicts on `pydantic` / `click` / `pyyaml`). Plain Python tool functions (the BYO pattern in our `langgraph-byo` template) wrap with `govern()` with the same API surface as `agent_framework` tools.

**Design impact:** `langgraph-byo` template integration is in scope for v0.24 (answer to reviewer question 6 above). Do NOT defer to v0.25.

### Finding 4 — Policy condition DSL is not what the docs imply (Phase 3 prerequisite)

When the spike called `safe_db('SELECT 1')` against a policy with `condition: "input contains 'DROP TABLE'"` and `defaults: { action: allow }`, AGT raised:

```
GovernanceDenied: Action denied by policy rule 'None': No matching rules, using default
```

This is a **deny on a call we expected to allow**. Same behavior on both `agent_framework`-decorated functions and plain Python functions. Most likely cause: the condition string `"input contains 'DROP TABLE'"` does not resolve against positional call arguments — AGT's evaluator probably requires either:

- An explicit `input=` keyword argument: `safe_db(input='SELECT 1')`, OR
- A different field-reference syntax that maps to call-context fields, OR
- A different default-action interpretation than `defaults: { action: allow }` documents

**This is a policy-authoring gotcha, not an integration blocker** — the integration code path works; the policy DSL needs a focused mini-spike before we ship any `policy.yaml` template.

**Design impact (Phase 3 prerequisite):**
1. Phase 3 starts with a 30-min focused sub-spike on AGT's condition evaluation rules: read `agentmesh.governance.policy` source for the field-resolution logic; document what `condition:` strings actually evaluate against; capture rules for the policy.yaml template we ship.
2. Until that's resolved, our `governance/policy.yaml` starter template must explicitly say "examples are illustrative; run `agt lint-policy` *and* a deny-path test before deploy."
3. The `/prepare-deploy` AGT gate should run a smoke test: call the deployed governed function with a known-deny input AND a known-allow input, fail if either behaves unexpectedly. This catches the docs-vs-reality gap before production.

### Finding 5 — `AGENTMESH_RELAY_TOKEN` env var (Tier 3 add-on territory)

On `import agentmesh.governance`, AGT prints:
```
AGENTMESH_RELAY_TOKEN is not set — the relay will accept unauthenticated connections.
Set this env var in production.
```

This suggests AGT has a remote **trust-mesh relay** component that listens for unauthenticated connections by default. For our in-process `govern()` Tier 1 path, the relay is not used — but the warning will appear in Foundry container logs and may worry operators.

**Design impact:**
- Phase 3 adds an env var `AGENTMESH_RELAY_DISABLED=1` (or equivalent — check AGT docs) to the template's deployment manifest to silence the warning when the relay isn't used.
- The relay itself maps to AGT's `agentmesh_platform` SPIFFE/DID layer — which is already on the Tier 3 NOT-integrated list. Add a callout to §2 confirming this is intentional.

### What sub-spikes did NOT confirm (still open for Phase 3)

- `agt lint-policy` CLI exact arguments and exit codes (need to run it against the corrected-syntax policy).
- Whether `mcp_security_gateway` is in-process (importable as a module) or requires a separate sidecar.
- AGT performance overhead per `govern()` call (the sub-ms claim from README; affects latency budgets in `foundry-prod-readiness`).

These are Phase 3 measurements, not blockers for the design lock.

---

## 12. Updated reviewer asks (after Phase 2)

Reviewer questions 1-6 from §10 still apply. Two **additional** questions from the sub-spike findings:

7. Is the corrected OTel architecture (rely on AGT's native `agt.*` span emission, no `on_deny` cross-link callback) acceptable? It's strictly simpler than the original §3 design.
8. Acceptable to spend the first 30 min of Phase 3 on a policy-DSL mini-spike (Finding 4) before any other code lands? Without it, the `policy.yaml` template we ship would likely be broken.
