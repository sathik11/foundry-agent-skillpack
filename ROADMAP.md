# Roadmap

The skillpack is at **v0.23.0** (May 2026). What's next is sequenced by *value of unblocking* × *real cost of building*. Open follow-ons are tracked as `TD-N` entries in [foundry-agent-skillpack/TECHNICAL_DEBT.md](foundry-agent-skillpack/TECHNICAL_DEBT.md).

For the rendered version with cross-links, see the [docs site Roadmap page](docs/src/content/docs/roadmap.md).

---

## Shipped recently

### v0.23.0 (May 2026) — TD-24 + TD-25 close-out (api-version drift + multi-account discovery)

- [x] **TD-24 — api-version drift.** Four stale or preview `api-version=` pins in `az rest --uri` calls were silently failing (`InvalidResourceType` swallowed by `|| echo '[]'` fallbacks). Bumped to current GA after verifying against `az provider show -n <namespace>`: `discover-target.sh` projects REST 2024-10-01→2026-03-01, `check-identities.sh` projects REST 2025-04-01-preview→2026-03-01, `check-service-endpoint-policy.sh` 2024-05-01→2025-07-01, `deep-walk-firewall.sh` ruleCollectionGroups 2024-05-01→2025-09-01, plus `two-identities.md` prose snippet bumped to GA. `discover-target.sh` now explicitly captures stderr from `az rest` so future drift logs `[!] Projects API failed (rc=N). Bump api-version or check RBAC.` instead of returning empty.
- [x] **TD-25 — single-account enumeration bug in `discover-target.sh`.** The script pulled `.[0]` for projects + deployments, silently losing data on multi-account RGs (typical for multi-region setups). Per-account loop now iterates every AIServices account; account [0] emits the un-suffixed primary keys for backwards compatibility, accounts [1..N] emit aggregate `ACCOUNT_<n>_PROJECT_NAMES=p1,p2` + `ACCOUNT_<n>_DEPLOYMENT_NAMES=d1,d2,d3` keys. Verified on a 3-account RG: projects 0→2, deployments 8→19, `DISCOVERY_STATUS` partial→complete.
- [x] **TD-26 opened (preventive).** Resource Graph hybrid for `discover-target.sh` — one ARG query covers accounts + projects + ACRs (no api-version pin; eliminates the TD-24 bug class for those types), then parallel `account deployment list` fan-out for deployments (ARG verified does NOT index `accounts/deployments`). PoC measured 4× faster than post-TD-25 baseline. Not landed yet because requires the `resource-graph` `az` extension; needs corp-policy-blocked-extension fallback verified before shipping.
- [x] **TD-27 opened (preventive).** Central api-version registry (`.apm/scripts/_api-versions.sh`) + shared error-surfacing helper. Below the indirection-cost threshold today (5 inline pins), tracked for when the count grows.
- [x] **Maintainer skill update.** `foundry-skillpack-builder` SKILL.md gains invariant #9 (api-versions must be pinned to current GA and verified on touch), a new symptom→owner row for `InvalidResourceType` / silent-empty results, an Authoritative-Sources routing table (Microsoft Learn MCP for service behavior, context7 for upstream libraries, `az provider show` for ARM api-versions, CLI `--help` for `az`/`azd`/`apm`), and two new anti-pattern entries.
- [x] **Fresh-laptop install script.** New `scripts/install-prereqs.sh` at repo root (macOS / Linux / WSL2). Auto-detects package manager (brew / apt), checks then installs only what's missing (`az` ≥ 2.80, `azd` ≥ 1.24 + `azd ai agent` extension, `jq`, `python3.12+`), prints the manual next-steps it deliberately cannot do (`az login`, subscription pick, Reader-role check with the exact `az role assignment list` command). Flags: `--dry-run`, `--no-python`, `--no-azd`. Re-runnable. Consumer one-liner: `curl -fsSL .../install-prereqs.sh | bash`.
- [x] **Prerequisites docs.** Root README gains a Prerequisites section + Windows callout. `docs/install.md` augmented with the full per-tool justification table (audited script-usage counts), a "verify everything" one-liner, and an explicit Windows-paths table (WSL2 supported, Git Bash unsupported, PowerShell-7 native under bake-off). Skillpack README slimmed to point at docs (avoid drift).
- [x] **TD-28 opened.** Cross-OS script runtime — bash + PowerShell-7 dual-script bake-off. **v0.24 bake-off (research only, no consumer-visible pwsh scripts), v0.25 ship decision** (migrate hot-path scripts to pwsh siblings, OR close TD-28 with the data and stay bash + WSL2). Includes parity-test harness design (mocked `az` + golden fixtures + CI gate on `ubuntu` / `macos` / `windows-latest`) so drift surfaces at PR time, not production-failure time. Explicit decision criteria for "dual wins" vs "abandon dual".
- [x] **Positioning vs Microsoft Agent Governance Toolkit (AGT).** New "How we fit alongside AGT" section in root README + dedicated docs page [`concepts/related-work.md`](docs/src/content/docs/concepts/related-work.md). Two-layer model, dimension-by-dimension comparison, vocabulary-overlap map, OWASP Agentic Top 10 split across both layers, and explicit adopt-and-integrate stance — AGT is runtime middleware, we are deploy + lifecycle orchestration; complementary layers of the same stack, intended to be used together.
- [x] **TD-29 opened (adopt + integrate, v0.24 firm).** AGT as a declarable `runtime_governance: agt` layer in `agent-capabilities.yaml` — container `requirements.txt` injection, agent template `govern(...)` wraps, OTel cross-link to AGT decisions, `/audit-drift` reconciliation of declared policy file. `foundry-guardrails` skill gains a Layer 0 (deterministic runtime enforcement) ahead of the existing four-layer model. Firmed to v0.24 as the strategic-credibility headline; runs sequentially before TD-28 lands its decision in v0.25.

## Planned

### v0.24 — AGT integration headline + cross-OS bake-off (research)

- **TD-29 (ship):** First-class AGT integration. `runtime_governance: agt` key in `agent-capabilities.yaml`; `/prepare-deploy` injects `agent-governance-toolkit[full]` into the agent's container `requirements.txt`; templates wrap declared tools with `govern(...)`; eval rules cross-link AGT decisions via OTel `evaluator.agt.*` spans; `/audit-drift` reconciles declared policy file against the deployed container; `foundry-guardrails` skill gains a real Layer 0 section.
- **TD-28 (research, no ship):** Build `tests/parity/` harness (mocked `az` + golden fixtures), port `discover-target.sh` to `discover-target.ps1` as the bake-off candidate, run on `ubuntu-latest` / `macos-latest` / `windows-latest` CI matrix, measure LOC delta, divergence, Windows smoke pass. **No `.ps1` files ship to consumers in v0.24** — outcome informs the v0.25 decision.
- **TD-19 final close:** Remove the `aliases: [foundry-agent-harness]` line from `foundry-agent-skillpack/apm.yml`. Add a final-warning release note pointing at TD-19 history.

### v0.25 — Cross-OS bake-off decision (ship or close)

- **TD-28 (decision ships):** Based on v0.24 bake-off data, either: (a) phased migration of remaining hot-path scripts to pwsh siblings with parity-test CI gate; OR (b) close TD-28 with the data, document why we stayed bash + WSL2, and treat native Windows as a known unsupported configuration.
- **TD-26 (likely):** Resource Graph hybrid for `discover-target.sh` (4× PoC speedup). Pending verification of fallback path on tenants that block the `resource-graph` `az` extension.
- **TD-30 (compliance mapping):** Formal OWASP Agentic Top 10 / NIST AI RMF mapping grounded in the actual AGT + skillpack mechanisms that ship in v0.24. Promotes the [related-work](docs/src/content/docs/concepts/related-work.md) coverage table from positioning copy to a defensible compliance claim.

### v0.22.0 (May 2026) — TD-23 close-out (inbound firewall for private Foundry agents on Teams)

- [x] **TD-23 — inbound firewall coverage** for the silent-publish-success failure mode on private Foundry accounts. Bot Framework Channel Adapter calls land from the public Microsoft backbone (Teams service tag `52.112.0.0/14`, `52.122.0.0/15`) and cannot reach a `publicNetworkAccess=Disabled` Foundry endpoint — `@mention` succeeds, typing indicator fires, reply never lands. Closure ships the runbook + paste-ready scaffold + verification.
- [x] **`foundry-teams-workiq/inbound-firewall.md`** — 8-section runbook: architecture, APIM v2 / YARP / AppGW+APIM decision matrix, paste-ready `<validate-jwt>` policy, prereqs (Key Vault-backed cert because v2 tiers don't support free managed cert + Microsoft-suspended-through-2026-06-30 notice), firewall worksheet, 3-probe verification, 6-row failure-mode table, anti-patterns.
- [x] **`apim-v2-vnet-integrated.bicep`** — paste-ready APIM StandardV2 + outbound VNet integration + custom domain (KV cert) + API/operation/policy/product wiring. `@allowed` SKU constrained to `StandardV2` / `PremiumV2`; subnet delegation `Microsoft.Web/serverFarms`.
- [x] **`render-apim-policy.sh`** — emits canonical policy XML for non-Bicep deploys; `--inline` substitutes APIM named-value placeholders with concrete values from `agent-status.json`. Byte-identical to the Bicep policy block.
- [x] **`probe-inbound-chain.sh`** — 3-probe verifier (TLS / missing-auth 401 / synthetic-invalid-JWT 401); `--stamp` writes `publish.inbound_chain` into `agent-status.json` on full pass.
- [x] **`agent-status.json` schema v1.2** — additive `publish.inbound_chain` block; no `schema_version` bump.
- [x] **`/publish-teams` Step 0a** — branches on private-Foundry detection (`network.class == "byo_vnet"` OR `publicNetworkAccess == "Disabled"`) and prints the inbound-firewall handoff banner before preflight.
- [x] **Cross-skill callouts:** `foundry-prod-readiness/networking.md` Bot Service asymmetry callout + reply-FQDN allowlist (`smba.trafficmanager.net`, `login.botframework.com`); `network-troubleshooter.md` symptom triage entry; `foundry-failure-modes/SKILL.md` F-20.

### v0.21.0 (May 2026) — Operator mode + discovery scripts

- [x] **Operator mode (try-first pattern).** Scripts now attempt actions directly and only emit runbooks on 403, replacing the old persona-gated “always emit runbook” behavior. `operator_mode: true` (default) written to `agent-capabilities.yaml` by `/plan-agent` Step 0a; read by all downstream prompts. Set `false` for SOC-monitored environments. See `foundry-roles/operator-mode.md`.
- [x] **Discovery scripts.** `discover-target.sh` (account + project + ACR + model in one call), `select-model.sh` (auto-selects when unambiguous), `safe-azd-init.sh` (guards against file clobber + .git reinit).
- [x] **Batch preflight.** `preflight-roles.sh` takes a prompt name and checks all required roles in one call. Fixes the wrong-interface `preflight-role.sh plan-agent <sub> <rg>` calls.
- [x] **Operator-mode grant scripts.** `try-or-runbook.sh` (core primitive), `ensure-provider-registration.sh`, `grant-fabric-workspace-role.sh` (partial TD-1 closure), rewritten `grant-purview-dlp-access.sh`.
- [x] **Prompt updates.** `/plan-agent` and `/prepare-deploy` rewritten to use discovery + batch preflight scripts.

### v0.20.0 (May 2026) — TD-2 + TD-10 close-out

- [x] **TD-2 — `/publish-teams` orchestration prompt** shipped. New prompt detects new vs legacy agent object model, preflights `Microsoft.BotService` + secret scan + BYO-VNet/public-Bot mismatch, patches `agent.yaml` with `BotServiceRbac` + Activity protocol, prints (does not execute) `azd ai agent publish`, captures the project→application identity flip, dispatches `/configure-rbac post_publish=true` for RBAC re-fan, and emits an M365 admin approval runbook.
- [x] **`/configure-rbac post_publish=true`** mode added — skips Phase 1/2, re-fans Phase 3 grants against the published application identity, writes to `rbac.capability_grants_post_publish` (preserves pre-publish state for audit).
- [x] **`agent-status.json` schema v1.1** — additive `publish` section; `agent_status.py` `ALLOWED_SECTIONS` extended.
- [x] **TD-10 — `deep_network` opt-in flag** on `/prepare-deploy`. Three-layer close-out: deep-walk scripts (`deep-walk-nsg.sh`, `deep-walk-firewall.sh`, `check-service-endpoint-policy.sh`) behind `--deep <agent-subnet> [<firewall-id>] <fqdns...>` on `check-source-network.sh`; paste-ready Bicep snippet at `foundry-prod-readiness/scripts/network/templates/byo-vnet-with-pe.bicep`; new `foundry-prod-readiness/network-troubleshooter.md` symptom→fix runbook.

### v0.19.0 (May 2026)

- [x] Package renamed from `foundry-agent-harness` → `foundry-agent-skillpack`. `aliases: [foundry-agent-harness]` ships through v0.20.0 (deferred from original v0.20.0 retirement — see TD-19).
- [x] Astro Starlight documentation site under `docs/`.
- [x] Azure Static Web Apps deployment workflow.
- [x] Docs drift checker (`docs/scripts/check-drift.mjs`) — non-blocking surface-drift detection between skillpack sources and the docs site. Tracked under TD-17.

### v0.18.0 (May 2026)

- [x] Rename `foundry-agent-engineering` → `foundry-agent-harness` (superseded by v0.19.0 rename to `foundry-agent-skillpack`).
- [x] TD-15 entry added (Microsoft Learn submission, post-1.0).

---

## Next minor (v0.23)

| Item | Source | Notes |
|---|---|---|
| **TD-19 — retire `foundry-agent-harness` alias** | TECHNICAL_DEBT | Drop `aliases: [foundry-agent-harness]` from `apm.yml`. Breaking change for any consumer still pinning the old name — coordinate with the next release notes. |
| **TD-14 — External persistence for Invocations agents** | TECHNICAL_DEBT | Cosmos / Redis / Storage Tables patterns; new `persistence` block in `agent-capabilities.yaml`; per-store Phase B grant scripts. |
| **Daily docs-scan workflow** | TECHNICAL_DEBT | GitHub Action that diffs Microsoft Learn pages we link to and opens an issue when surface changes. Underpins TD-4 / TD-8 / TD-9 close-outs. |
| **`/setup-evals` writes to `agent-status.json` `evals` block** | gap noted in `agent-status-schema.md` | Quick follow-on; section already reserved. |

## 1.0 candidate

| Item | Source | Trigger |
|---|---|---|
| **TD-7 — `--wait-for-rbac` flag** | TECHNICAL_DEBT | When users hit propagation 403s repeatedly |
| **TD-13 — `--ast` flag for `scan_knowledge_refs.py`** | TECHNICAL_DEBT | When first user reports false negative |
| **TD-6 — Consumer-smoke matrix CI job** | TECHNICAL_DEBT | Before public 1.0 |
| **First-class APIM `kind` in `verify-source-rbac.sh`** | Recipe 05 callout | Cleans up Recipe 05 manual fallback |

## Post-1.0

| Item | Source |
|---|---|
| **TD-15 — Microsoft Learn submission** | shipped infra |
| **`register-custom-agent` flow** (separate `foundry-control-plane` skill) | brainstorm |
| **TD-4 promotion — Foundry-DLP `block` mode out of preview-warning** | TECHNICAL_DEBT |
| **TD-1 Fabric workspace API automation** | TECHNICAL_DEBT |
| **Legacy-agent upgrade-gesture branch retirement in `/publish-teams`** | TD-2 verification track | drops once MS Learn legacy→new upgrade gesture GAs |

## Backlog (ideas tracked, not committed)

- Multi-language brownfield scanner (TypeScript / C# in addition to Python).
- VS Code Foundry extension surface that renders the audit-drift report inline.
- Per-skill testing sub-docs (today recipes are the only end-to-end test path).

## Explicit non-goals

Decisions made *not* to build:

- **Auto-fix in `/audit-drift`** — drift detection and remediation are different code paths.
- **Data-plane smoke retrieves in `/audit-drift`** — that's `/verify-agent`'s job; audit shouldn't trigger live agent invocations weekly.
- **Hosting our own MCP server** — boundary stays at "knowledge package + scripts."
- **Separate `agent-graph.json` artifact** — subsumed by `agent-status.json`.
- **Executing `azd ai agent publish` from `/publish-teams`** — mutating publish event stays operator-visible (matches the `azd up` boundary). The prompt prints the CLI; the human runs it.
- **Executing role assignments from `refan-rbac-post-publish.sh`** — script emits the exact `/configure-rbac post_publish=true` invocation; grants stay in the audited prompt path.

