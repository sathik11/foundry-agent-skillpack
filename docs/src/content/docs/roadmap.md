---
title: Roadmap
description: What's done, what's next, and what's deferred — with the reasoning for each.
---

The skillpack is at **v0.23.0** (May 2026). What's next is sequenced by *value of unblocking* + *real cost of building*. Open follow-ons are tracked in [TECHNICAL_DEBT.md](/technical-debt/) on disk.

## Shipped recently

### v0.23.0 — TD-24 + TD-25 close-out (api-version drift + multi-account discovery)

- ✅ **TD-24 — api-version drift** in `az rest --uri "...?api-version=…"` calls. Four stale or preview pins were silently failing because the `|| echo '{"value":[]}'` fallback swallowed ARM's `InvalidResourceType` response and returned an empty result. Bumped to current GA after verifying each against `az provider show -n <namespace>`: `discover-target.sh` projects REST `2024-10-01`→`2026-03-01`, `check-identities.sh` projects REST `2025-04-01-preview`→`2026-03-01`, `check-service-endpoint-policy.sh` `2024-05-01`→`2025-07-01`, `deep-walk-firewall.sh` ruleCollectionGroups `2024-05-01`→`2025-09-01`, plus `two-identities.md` prose snippet bumped to GA. `discover-target.sh` now captures stderr from `az rest` explicitly so future drift surfaces as `[!] Projects API failed (rc=N). Bump api-version or check RBAC.` instead of an empty result.
- ✅ **TD-25 — single-account enumeration bug** in `discover-target.sh`. The script pulled `.[0]` for projects + deployments and silently lost data on multi-account RGs (typical for multi-region setups). Per-account loop now iterates every AIServices account; account [0] emits the un-suffixed primary keys for backward compatibility, accounts [1..N] emit aggregate `ACCOUNT_<n>_PROJECT_NAMES=p1,p2` and `ACCOUNT_<n>_DEPLOYMENT_NAMES=d1,d2,d3` keys plus stderr summaries. Verified on a 3-account RG: projects 0→2, deployments 8→19, `DISCOVERY_STATUS` partial→complete.
- ✅ **TD-26 opened (preventive).** Resource Graph hybrid for `discover-target.sh` — one `az graph query` covers accounts + projects + ACRs in one round trip with no api-version pin (ARG schema is centrally managed → eliminates the TD-24 bug class for those resource types). PoC measured 4× faster than post-TD-25 baseline. Deployments still need per-account fan-out — verified that ARG does NOT index `accounts/deployments`. Not landed in v0.23.0 because the `resource-graph` `az` extension may be policy-blocked on locked-down operator machines and the fallback path needs to be verified on such a tenant first.
- ✅ **TD-27 opened (preventive).** Central api-version registry (`.apm/scripts/_api-versions.sh` exporting named constants) + shared `_az_rest_capture()` helper to replace `|| echo '[]'` with explicit stderr surfacing. Below the indirection-cost threshold today (5 inline pins); tracked so the 6th hand-pinned api-version triggers the registry build.
- ✅ **Maintainer skill update — `foundry-skillpack-builder` SKILL.md.** New invariant #9 ("api-versions must be pinned to current GA and verified on touch") with verification one-liner. New symptom→owner row routing `InvalidResourceType` / silent-empty symptoms to the api-version audit pattern. New **Authoritative sources** section: routes ARM api-versions to `az provider show`, service behavior + REST shapes to Microsoft Learn MCP (`microsoft_docs_search` + `microsoft_docs_fetch`), upstream libraries (`azure-ai-projects`, `langgraph`, etc.) to context7 MCP, and `az`/`azd`/`apm` CLI behavior to `--help` in a live terminal. Plus two new anti-pattern entries (api-version pinning, training-data recall).
- ✅ **Fresh-laptop install script + Windows guidance.** New `scripts/install-prereqs.sh` at repo root — macOS / Linux / WSL2; auto-detects `brew` or `apt`; installs only what's missing; `--dry-run` / `--no-python` / `--no-azd` flags; re-runnable. Prints the manual next-steps it deliberately cannot do (`az login`, subscription pick, Reader-role verification). Consumer one-liner: `curl -fsSL .../install-prereqs.sh | bash`. Docs add the full per-tool justification table with audited usage counts (79 `az` invocations, 104 `jq` invocations), a "verify everything" snippet, and an explicit Windows-paths table: **WSL2 supported, Git Bash unsupported, PowerShell-7 under bake-off**.
- ✅ **TD-28 opened.** Cross-OS script runtime — bash + PowerShell-7 dual-script bake-off. **v0.24 bake-off (research only), v0.25 ship decision.** Three options evaluated (parallel `.sh`+`.ps1`, Python SDK rewrite, status-quo); dual-native chosen for the bake-off because it mirrors Microsoft Learn's own dual bash/pwsh doc pattern. Includes parity-test harness design (mocked `az` binary + golden fixtures + CI gate on `ubuntu` / `macos` / `windows-latest`) so drift surfaces at PR time, not production-failure time. Explicit decision criteria for "dual wins" vs "abandon dual" — outcome is not pre-decided.
- ✅ **Positioning vs Microsoft Agent Governance Toolkit (AGT).** New "How we fit alongside AGT" section in root README + dedicated docs page [Related work](/concepts/related-work/). Two-layer model (AGT = runtime middleware; us = deploy + lifecycle orchestration), dimension-by-dimension comparison, vocabulary-overlap map (red team / policy / identity / audit / guardrails), OWASP Agentic Top 10 split across both layers, and explicit adopt-and-integrate stance. AGT lists Azure AI Foundry as one of its deployment targets — we are the layer that gets Foundry agents deployed correctly before AGT wraps their tool calls.
- ✅ **TD-29 opened (adopt + integrate, v0.24 firm).** AGT as a declarable `runtime_governance: agt` layer in `agent-capabilities.yaml`. When declared: `/prepare-deploy` injects `agent-governance-toolkit[full]` into container `requirements.txt`, agent templates wrap declared tools with `govern(...)`, Foundry-native eval rules cross-link AGT decisions through OTel `evaluator.agt.*` spans, `/audit-drift` reconciles policy file against deployed container. `foundry-guardrails` gains a Layer 0 (deterministic runtime enforcement) ahead of the existing four-layer model. Firmed to v0.24 as the strategic-credibility headline.

## Planned

### v0.24 — AGT integration headline + cross-OS bake-off (research)

- **TD-29 (ship):** first-class AGT integration. `runtime_governance: agt` key in `agent-capabilities.yaml`; `/prepare-deploy` injects `agent-governance-toolkit[full]` into the agent container; templates wrap declared tools with `govern(...)`; eval rules cross-link AGT decisions via OTel; `/audit-drift` reconciles declared policy file against the deployed container; `foundry-guardrails` gains a real Layer 0 section.
- **TD-28 (research, no ship):** build `tests/parity/` harness (mocked `az` + golden fixtures), port `discover-target.sh` to `discover-target.ps1`, run on `ubuntu` / `macos` / `windows-latest` CI matrix, measure LOC delta + divergence + Windows smoke. **No `.ps1` files ship to consumers in v0.24** — outcome informs the v0.25 decision.
- **TD-19 final close:** remove the `aliases: [foundry-agent-harness]` line.

### v0.25 — Cross-OS bake-off decision (ship or close)

- **TD-28 (decision ships):** based on v0.24 bake-off data, either (a) phased migration of hot-path scripts to pwsh siblings with parity-test CI gate, OR (b) close TD-28 with the data and document why we stayed bash + WSL2.
- **TD-26 (likely):** Resource Graph hybrid for `discover-target.sh` (4× PoC speedup), pending fallback verification on tenants that block the `resource-graph` extension.
- **TD-30 (compliance mapping):** formal OWASP Agentic Top 10 / NIST AI RMF mapping grounded in actual AGT + skillpack mechanisms shipped in v0.24.

### v0.22.0 — TD-23 close-out (inbound firewall for private Foundry agents on Teams)

- ✅ **TD-23 — inbound firewall coverage** for the published-bot silent-fail mode (typing indicator → no reply) on `publicNetworkAccess=Disabled` Foundry accounts. Closes the gap where Bot Framework Channel Adapter calls land from the public Microsoft backbone (Teams service tag `52.112.0.0/14`, `52.122.0.0/15`) and cannot reach a private Foundry endpoint.
- ✅ **`foundry-teams-workiq/inbound-firewall.md`** — 8-section runbook: architecture, APIM v2 / YARP / AppGW+APIM decision matrix, paste-ready `<validate-jwt>` policy with `login.botframework.com` OIDC config, prereqs checklist (Key Vault-backed cert because v2 tiers don't support free managed cert, plus Microsoft-suspended-through-2026-06-30 notice), firewall worksheet, 3-probe verification, 6-row failure-mode table, anti-patterns.
- ✅ **`apim-v2-vnet-integrated.bicep`** — paste-ready scaffold for APIM StandardV2 + outbound VNet integration + custom domain (KV cert) + API/operation/policy/product wiring. `@allowed` constrains SKU to `StandardV2` / `PremiumV2` (BasicV2 NOT supported for VNet integration). Subnet delegation `Microsoft.Web/serverFarms`.
- ✅ **`render-apim-policy.sh`** — emits canonical policy XML for non-Bicep deploys; `--inline` substitutes APIM named-value placeholders with concrete values from `agent-status.json`. Byte-identical to the Bicep `<policies>` block (three sources, one truth).
- ✅ **`probe-inbound-chain.sh`** — 3-probe verifier (TLS / missing-auth 401 / synthetic-invalid-JWT 401). `--stamp` writes `publish.inbound_chain` into `agent-status.json` on full pass.
- ✅ **`agent-status.json` schema v1.2** — additive `publish.inbound_chain` block. No `schema_version` bump.
- ✅ **`/publish-teams` Step 0a** — branches on `network.class == "byo_vnet"` OR `publicNetworkAccess == "Disabled"`; prints inbound-firewall handoff banner before preflight.
- ✅ **Cross-skill callouts:** `networking.md` Bot Service asymmetry callout + reply-FQDN allowlist (`smba.trafficmanager.net`, `login.botframework.com`); `network-troubleshooter.md` symptom triage entry; `foundry-failure-modes/SKILL.md` F-20.

### v0.21.0 — Operator mode + discovery scripts

- ✅ **Operator mode (try-first pattern).** Scripts attempt actions directly; runbook only on 403. `operator_mode: true` (default) stamped in `agent-capabilities.yaml` by `/plan-agent` Step 0a. Set `false` for SOC-monitored environments. See `foundry-roles/operator-mode.md`.
- ✅ **Discovery scripts.** `discover-target.sh` (account + project + ACR + model in one call), `select-model.sh` (auto-selects when unambiguous), `safe-azd-init.sh` (guards file clobber + .git reinit).
- ✅ **Batch preflight.** `preflight-roles.sh` checks all roles a prompt needs in one call.
- ✅ **Operator-mode grant scripts.** `try-or-runbook.sh`, `ensure-provider-registration.sh`, `grant-fabric-workspace-role.sh` (partial TD-1 closure), rewritten `grant-purview-dlp-access.sh`.
- ✅ **Prompt rewrites.** `/plan-agent` and `/prepare-deploy` use discovery + batch preflight instead of ad-hoc MCP queries.

### v0.20.0 — TD-2 + TD-10 close-out

- ✅ **TD-2 — `/publish-teams` orchestration prompt** shipped. Detects new vs legacy agent object model, preflights `Microsoft.BotService` + secret scan + BYO-VNet/public-Bot mismatch, patches `agent.yaml` (`BotServiceRbac` + Activity protocol), prints the `azd ai agent publish` CLI (does not execute), captures the project→application identity flip, dispatches `/configure-rbac post_publish=true` for RBAC re-fan, and emits the M365 admin approval runbook.
- ✅ **`/configure-rbac post_publish=true`** mode added — skips Phase 1/2, re-fans Phase 3 grants against the published application identity, writes to `rbac.capability_grants_post_publish`.
- ✅ **`agent-status.json` schema v1.1** — additive `publish` section.
- ✅ **TD-10 — `deep_network` opt-in** on `/prepare-deploy`. Three-layer close-out: deep-walk scripts (NSG, Azure Firewall, SEP) behind `--deep` on `check-source-network.sh`; paste-ready Bicep snippet for BYO VNet + PE + Private DNS; new `network-troubleshooter.md` symptom→fix runbook.

### v0.19.0

- ✅ Package renamed from `foundry-agent-harness` → `foundry-agent-skillpack` (`aliases: [foundry-agent-harness]` ships through v0.23.0 — retirement targeted for v0.24 per TD-19).
- ✅ Astro Starlight documentation site (this site).
- ✅ Azure Static Web Apps deployment workflow.
- ✅ Docs drift checker (`docs/scripts/check-drift.mjs`).

### v0.18.0

- ✅ Rename `foundry-agent-engineering` → `foundry-agent-harness` (superseded in v0.19.0).
- ✅ ROADMAP at repo root + on this site.

## Next minor (v0.23)

| Item | Source | Status |
| --- | --- | --- |
| **TD-19 — retire `foundry-agent-harness` alias** | TECHNICAL_DEBT | Planned (breaking — coordinate with release notes) |
| **TD-14 — External persistence for Invocations agents** (Cosmos / Redis / Storage Tables patterns; new `persistence` block in `agent-capabilities.yaml`) | TECHNICAL_DEBT | Planned |
| **Daily docs-scan workflow** (catches Foundry preview drift; underpins TD-4 / TD-8 / TD-9 close-outs by surfacing API rename + region list changes) | TECHNICAL_DEBT | Planned |
| **`/setup-evals` writes to `agent-status.json` `evals` block** | gap noted in agent-status-schema | Quick follow-on |

## 1.0 candidate

These should land before declaring 1.0:

| Item | Source | Trigger |
| --- | --- | --- |
| **TD-7 — `--wait-for-rbac` flag** (`/verify-agent` polls a known endpoint until success or 20 min timeout) | TECHNICAL_DEBT | When users hit propagation 403s repeatedly |
| **TD-13 — `--ast` flag for `scan_knowledge_refs.py`** (catches aliased imports, conditional imports, framework-specific tool wrappers) | TECHNICAL_DEBT | When first user reports false negative |
| **TD-6 — Consumer-smoke matrix CI job** (validates a fresh consumer project resolves both packages) | TECHNICAL_DEBT | Before public 1.0 |
| **First-class APIM `kind` in `verify-source-rbac.sh`** | Recipe 05 callout | Cleans up Recipe 05 |

## Post-1.0

| Item | Source | Notes |
| --- | --- | --- |
| **TD-15 — Microsoft Learn submission** | Roadmap doc | Months-long content + IP review; aim once adoption justifies |
| **`register-custom-agent` flow** (true outside-Foundry agents — separate `foundry-control-plane` skill) | Brainstorm | Distinct from Invocations protocol; agents running in your own AKS / EKS / on-prem |
| **TD-4 promotion — Foundry-DLP `block` mode out of preview-warning** | TECHNICAL_DEBT | When Purview classification API + token surface confirmed GA |
| **TD-1 Fabric workspace API automation** (replace print-only with API call when Fabric-aud token can be obtained cleanly) | TECHNICAL_DEBT | When Fabric workspace add is exposed via Graph or similar |
| **Legacy-agent upgrade-gesture branch retirement in `/publish-teams`** | TD-2 verification track | When MS Learn legacy → new-model upgrade gesture GAs |

## Backlog

Ideas tracked but not committed:

- Multi-language brownfield scanner (TypeScript / C# in addition to Python).
- VS Code Foundry extension surface that renders the audit-drift report inline.
- Per-skill testing sub-docs (today recipes are the only end-to-end test path).
- Foundry-skills sample sub-doc (today the SKILL.md is the only doc — could grow).

## Explicit non-goals

Things we have deliberately decided not to do:

- **Auto-fix in `/audit-drift`**. Drift detection and remediation are different code paths. `/audit-drift` reads; `/configure-rbac` + `/verify-agent` write. Auto-fix risks silently re-granting roles that were deliberately revoked.
- **Data-plane smoke retrieves in `/audit-drift`**. That's `/verify-agent`'s job — audit shouldn't trigger live agent invocations on a weekly schedule.
- **Hosting our own MCP server**. Boundary stays at "knowledge package + scripts." If we ever ship one, separate repo.
- **`agent-graph.json` as a separate artifact**. Subsumed by `agent-status.json` (one artifact, multiple readers).
- **Executing `azd ai agent publish` from `/publish-teams`**. Mutating publish stays operator-visible (matches the `azd up` boundary). The prompt prints the CLI; the human runs it.
- **Executing role assignments from `refan-rbac-post-publish.sh`**. Script emits the exact `/configure-rbac post_publish=true` invocation; grants stay in the audited prompt path.

## Read next

- [Technical debt](/technical-debt/) — the on-disk TD-N tracking that this roadmap is derived from.
- [Contributing](/contributing/) — how to propose roadmap items.
