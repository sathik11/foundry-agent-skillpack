---
title: Related work — how we fit alongside Microsoft Agent Governance Toolkit
description: Where this skillpack sits relative to AGT (runtime governance), Foundry SDK, azd ai agent, and other Microsoft + community agent tooling. Adopt-and-integrate posture, not compete.
---

This skillpack is one layer in a larger stack. The most important neighbouring project is **[Microsoft Agent Governance Toolkit (AGT)](https://github.com/microsoft/agent-governance-toolkit)** — production-grade runtime governance for AI agents, official `microsoft/` org, multi-language SDK, OpenSSF Scorecard, EU AI Act / NIST AI RMF / SOC 2 mappings, RFC 2119 specs with 992 conformance tests.

**Stated posture: adopt and integrate, not compete.** AGT lists Azure AI Foundry as one of its supported deployment targets. We are the deployment + lifecycle orchestration layer Foundry consumers need *before* AGT can wrap their tool calls at runtime.

## The two-layer model

```
                ┌────────────────────────────────────────────────────┐
                │  AGT (runtime middleware, inside the container)    │
                │  - Policy engine (YAML / OPA / Cedar)              │
                │  - Per-tool-call deny / require_approval / allow   │
                │  - Tamper-evident Merkle audit                     │
                │  - Identity: SPIFFE / DID / mTLS                   │
                │  - Kill switch, SLO, chaos testing                 │
                └─────────────────────▲──────────────────────────────┘
                                      │ wraps tool functions at runtime
                                      │
┌─────────────────────────────────────┴──────────────────────────────┐
│  This skillpack (deploy + lifecycle, outside the container)        │
│  - /plan-agent, /prepare-deploy, /configure-rbac                   │
│  - Entra Agent ID + project/agent/application identity flip        │
│  - Per-capability RBAC dispatcher                                  │
│  - Foundry-native EvaluationRule + RedTeam (azure-ai-projects SDK) │
│  - Purview DLP middleware (Layer 1.5) + Content Safety             │
│  - APIM-fronted MCP gateway · Teams publish flow                   │
│  - Per-agent durable state + read-only drift detection             │
└────────────────────────────────────────────────────────────────────┘
```

The arrow goes **up** because the runtime layer needs a deployed agent to wrap. We make the agent exist correctly; AGT governs what it does once running.

## Detailed comparison

| Dimension | AGT (runtime middleware) | This skillpack (deploy + lifecycle) |
|---|---|---|
| **When in the lifecycle** | Inside the agent container, per tool call | Before `azd up` and across post-deploy operations |
| **Distribution** | Library — `pip install agent-governance-toolkit[full]`, also npm / NuGet / cargo / go | APM package consumed by coding agents (Copilot Chat / Claude Code / Cursor / Windsurf / …) |
| **Output artifact** | `GovernanceDenied` exception at the call site + Merkle decision record | Foundry `EvaluationRule` + `RedTeam` + `ContinuousEvalRule` resources · APIM Bicep · Entra Agent ID · per-capability RBAC grants · `agent-status.json` · drift report |
| **Cloud** | Multi-cloud — Azure / AWS / GCP / Docker | Foundry-specific |
| **Framework** | 14+ adapters: MAF, Semantic Kernel, AutoGen, LangGraph, LangChain, CrewAI, OpenAI Agents SDK, Claude Code, Google ADK, LlamaIndex, Haystack, Mastra, Dify, smolagents | Foundry-native + `agent-framework` + LangGraph BYO templates |
| **Primary user** | Application developer writing agent code | DevOps / AI engineer / coding-agent operator deploying + governing agents on Foundry |
| **Identity model** | SPIFFE / DID / mTLS — cross-cloud zero-trust primitive | Entra Agent ID + Foundry project / agent / application identity model + identity-flip orchestration at publish time |
| **Policy model** | YAML / OPA / Cedar evaluated per tool call; `default_action: deny` available | `agent-capabilities.yaml` declares *which capability gates and middleware layers to provision* (different mechanism, different layer) |
| **Audit model** | Tamper-evident Merkle log of every decision | OTel spans → App Insights + `/audit-drift` reconciliation against `agent-status.json` |
| **MCP coverage** | MCP Security Gateway (tool poisoning, drift, hidden instructions, typosquatting) | External MCP wiring + APIM-as-MCP-frontdoor pattern (rate limit, OAuth, audit before MCP) |
| **What it does NOT do** | Provision Azure resources · grant RBAC · configure Foundry capabilities · orchestrate Teams publish · handle the project→application identity flip | Intercept tool calls at runtime · enforce per-action policy · provide a cross-framework SDK · ship multi-language packages |

## Where the vocabulary overlaps but the mechanism differs

| Concept | AGT mechanism | Our mechanism |
|---|---|---|
| "Red team" | Local CLI: `agt red-team scan ./prompts/ --min-grade B` | Creates a Foundry `RedTeam` resource via `azure-ai-projects` SDK — cloud-managed, scheduled, audited inside Foundry portal |
| "Policy" | YAML / OPA / Cedar engine deciding per tool call | `agent-capabilities.yaml` declaring middleware layers + Content Safety + Purview DLP + eval rules to provision |
| "Identity" | SPIFFE / DID issued by AGT to each agent | Entra Agent ID assigned by Foundry; we dispatch the per-capability RBAC matrix |
| "Audit" | Tamper-evident Merkle decision log | OTel spans + App Insights traces + `/audit-drift` reconciliation |
| "Guardrails" | Single in-process kernel that denies disallowed actions | Four-layer model (Middleware · Purview DLP · Content Safety · Eval/RedTeam) — see [Four-layer guardrails](/concepts/four-layer-guardrails/) |

Different mechanisms solving adjacent problems at different layers. **Both are needed for a production Foundry hosted agent.**

## OWASP Agentic AI Top 10 — where each layer covers what

AGT explicitly maps to 10/10 of the OWASP Agentic Top 10. We cover a different *subset* — primarily through provisioning + governance setup rather than runtime enforcement. The honest split:

| OWASP risk | AGT covers via | This skillpack covers via |
|---|---|---|
| **A1 Excessive Agency** | Per-tool-call policy deny + four privilege rings | Per-capability RBAC matrix (only the resources you declared are granted) |
| **A2 Identity Spoofing** | SPIFFE / DID / mTLS per-agent identity | Entra Agent ID + project→agent→application identity-flip orchestration |
| **A3 Hallucinated Tool Invocations** | MCP Security Gateway (tool poisoning, drift detection) | APIM-fronted MCP gateway (auth + rate limit + audit) |
| **A4 Memory Poisoning** | Policy on memory writes + Merkle audit | Foundry knowledge source RBAC verification + `/audit-drift` |
| **A5 Cascading Hallucinations** | Multi-agent trust scoring + delegation chains | Multi-agent orchestration patterns (siblings, data buffer, SSE streaming) |
| **A6 Privilege Compromise** | Privilege rings + kill switch | Per-capability RBAC + `try-or-runbook` operator mode + `/audit-drift` |
| **A7 Insecure Tool Use** | `govern(tool)` wrap + policy engine | Capability declaration → only declared sources accessible |
| **A8 Sensitive Information Disclosure** | Audit + policy on data egress | **Purview DLP middleware (Layer 1.5)** + Content Safety classification |
| **A9 Misaligned / Deceptive Behavior** | Continuous policy enforcement + RL training governance | Foundry-native continuous eval + scheduled eval + cloud red-team |
| **A10 Unexpected RCE / Code Generation** | Sandboxing (four privilege rings) | Network class verification (public / managed VNet / BYO VNet) + APIM allow-list |

Both layers cover most risks — **neither alone is sufficient for high-stakes deployments**. Runtime enforcement (AGT) is what makes denied actions structurally impossible; provisioning correctness (this skillpack) is what ensures the agent had the right identity, RBAC, network, and eval rules in the first place.

## Adopt-and-integrate plan — TD-29

Tracked under [TD-29 in TECHNICAL_DEBT.md](/technical-debt/). The intended shape (v0.24+ candidate):

1. **`agent-capabilities.yaml` accepts a new top-level key:**

   ```yaml
   runtime_governance:
     provider: agt                        # or 'none'
     policy_file: governance/policy.yaml  # AGT YAML / OPA / Cedar
     fail_mode: deny                      # deny | allow | require_approval
     audit_sink: merkle                   # merkle | otel | both
   ```

2. **`/prepare-deploy` gate**, when `runtime_governance.provider == agt`:
   - Injects `agent-governance-toolkit[full]` into the agent's container `requirements.txt`.
   - Validates the referenced policy file with `agt lint-policy`.
   - Emits the AGT-required env vars (`AZURE_CLIENT_ID` etc.) into the deployment manifest.

3. **Skillpack agent templates** (`agent-framework` and `langgraph-byo`) include a commented-out `govern(...)` wrap example next to each declared tool function — uncommented automatically when AGT is the declared provider.

4. **Foundry-native eval rules cross-link AGT decisions** through OTel spans (AGT decision records become `evaluator.agt.*` attributes), so the audit trail in App Insights includes per-tool-call policy outcomes alongside eval rule results.

5. **`foundry-guardrails` skill** gains an "AGT integration" section under Layer 0 (deterministic runtime enforcement, ordered before middleware) — current four-layer model becomes a five-layer model with AGT optional but recommended.

6. **`/audit-drift`** reconciles declared `runtime_governance.policy_file` against the policy file present in the deployed container image (drift case: someone bumped policy locally but didn't redeploy).

This is **Option 3** of the strategic choices: differentiate clearly AND integrate as a first-class declarable layer. The alternative (just integrate without differentiating) would leave the skillpack ambiguously positioned; the alternative (just differentiate without integrating) would force users to wire AGT themselves outside our orchestration.

## Other related projects worth knowing

| Project | Layer | How we relate |
|---|---|---|
| [`azd ai agent` extension](https://learn.microsoft.com/azure/developer/azure-developer-cli/azd-extensions) | Deployment CLI | We dispatch `azd up` through it; we never reimplement image build, agent create, version create, identity assignment |
| [`azure-ai-projects` Python SDK](https://learn.microsoft.com/python/api/overview/azure/ai-projects-readme) | Foundry control plane SDK | Our `foundry-evals/scripts/ensure_*.py` wrappers call this SDK directly; eval rules + red-team resources live inside Foundry, not as sideband artifacts |
| [Microsoft Foundry portal](https://ai.azure.com) | UI | Operators use it to view agents, projects, eval results, RBAC; we generate the same state programmatically |
| [Azure AI Toolkit (VS Code)](https://marketplace.visualstudio.com/items?itemName=ms-windows-ai-studio.windows-ai-studio) | IDE tooling | Adjacent — VS Code-side authoring; we are coding-agent-side lifecycle orchestration |
| [Semantic Kernel](https://github.com/microsoft/semantic-kernel) / [Microsoft Agent Framework](https://github.com/microsoft/agent-framework) | Agent runtime frameworks | We ship templates that scaffold agents using these; AGT wraps their tool calls; we orchestrate deployment + RBAC for them on Foundry |
| [APIM](https://learn.microsoft.com/azure/api-management/) | API gateway | We use it as the inbound front door for Teams → private Foundry (TD-23 close-out) and as MCP gateway pattern |
| [Microsoft Purview](https://learn.microsoft.com/purview/purview) | Data governance | We vendor Layer 1.5 DLP middleware that calls Purview classification API per turn |

## When to use what

- **Building a Foundry hosted agent that talks to Purview-protected data and publishes to Teams?** Use this skillpack for everything outside the container; add AGT inside the container for per-tool-call policy enforcement.
- **Building an agent on a non-Foundry runtime (local, AWS, GCP, your own server)?** Use AGT alone — this skillpack is Foundry-specific.
- **Just prototyping locally with LangGraph and no deployment yet?** Neither is strictly needed; reach for AGT when you start exposing tools that touch external systems.
- **Operating a fleet of agents across multiple teams?** AGT for runtime governance + telemetry; this skillpack for the per-Foundry-agent deployment lifecycle.

## Honest gaps (vs AGT)

We don't yet match AGT's governance hygiene. Tracked transparently:

- No `SECURITY.md`, `CODE_OF_CONDUCT.md`, `CONTRIBUTING.md` at repo root, `SUPPORT.md`, `CODEOWNERS`, `dependabot.yml` — basic OSS files AGT has.
- No CI security scans (CodeQL SAST, Gitleaks secret scanning) — AGT runs both weekly.
- No [OpenSSF Scorecard](https://scorecard.dev/) — AGT publishes one.
- No formal compliance mapping (OWASP / NIST AI RMF / EU AI Act / SOC 2) — AGT has all four. The OWASP table above is a start, not a formal mapping.
- No formal RFC 2119 specifications + conformance tests — AGT has 10 specs / 992 tests.

The first batch (governance hygiene files + CI security scans) is on the v0.24 punch-list. The compliance mapping + specs are longer-horizon investments.
