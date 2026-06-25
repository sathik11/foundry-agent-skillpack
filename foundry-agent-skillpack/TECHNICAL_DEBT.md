# Technical Debt

Tracked gaps and trade-offs in the foundry-agent-skillpack APM package. Each entry: what / why deferred / what would close it.

> **Rename history:**
> - **v0.18.0 (May 2026):** package renamed from `foundry-agent-engineering` → `foundry-agent-harness`.
> - **v0.19.0 (May 2026):** package renamed from `foundry-agent-harness` → `foundry-agent-skillpack`. `aliases: [foundry-agent-harness]` ships from v0.19.x through v0.23.0; slated to drop in v0.24. See [TD-19](#td-19--package-rename-foundry-agent-harness--foundry-agent-skillpack).
>
> Prior TD entries reference older names in commit history; the package contents are continuous. See [`ROADMAP.md`](../ROADMAP.md) for sequencing.

## TD-1 — Fabric workspace role assignment is print-only

**What:** `/configure-rbac` prints the Fabric portal/REST steps to add the per-agent identity as a workspace `Member` instead of executing the call.

**Why deferred:** The Fabric `POST /workspaces/{id}/roleAssignments` API requires a Fabric-aud delegated token (`api.fabric.microsoft.com/.default`), not an `https://management.azure.com/.default` token from `az`. Acquiring it cleanly inside an APM prompt requires either:
- A Service Principal that already has `Fabric Administrator` (chicken-and-egg), or
- An interactive `az login --scope api.fabric.microsoft.com/.default` flow that disrupts the prompt flow.

**Close-out:** Detect if the user is a Fabric admin (Graph: `directoryRoles` for `Fabric Administrator`); if so, prompt for explicit `az login --scope` and call the API. Otherwise stay print-only.

## ~~TD-2 — Teams publish orchestration~~ **(CLOSED in v0.20.0)**

**Status (v0.20.0):** Closed. The new-model identity-flip gap is now orchestrated by [`/publish-teams`](.apm/prompts/publish-teams.prompt.md) + [`/configure-rbac post_publish=true`](.apm/prompts/configure-rbac.prompt.md), backed by:

- [foundry-teams-workiq/publish-flow.md](.apm/skills/foundry-teams-workiq/publish-flow.md) — full flow documentation (preflight, agent.yaml patch, publish CLI handoff, identity-flip capture, RBAC re-fan, M365 admin runbook).
- [foundry-teams-workiq/scripts/preflight-publish.sh](.apm/skills/foundry-teams-workiq/scripts/preflight-publish.sh) — hard-gates `BotService` RP registration, `BYO_VNET_PUBLIC_BOT_MISMATCH`, continuous-eval rule presence, Purview enablement, and publish-metadata secret scan.
- [foundry-teams-workiq/scripts/refan-rbac-post-publish.sh](.apm/skills/foundry-teams-workiq/scripts/refan-rbac-post-publish.sh) — resolves the application identity and emits the exact `/configure-rbac post_publish=true` invocation.
- New `publish` section in [agent-status-schema.md](.apm/skills/foundry-deploy/agent-status-schema.md#publish--written-by-publish-teams-and-configure-rbac---post-publish-td-2) (schema v1.1, additive). `agent_status.py` `ALLOWED_SECTIONS` extended.
- `/configure-rbac` `post_publish` input added: skips Phase 1/2, re-fans Phase 3 grants against `publish.application_identity_principal_id`, writes to `rbac.capability_grants_post_publish` (preserves pre-publish state for audit), stamps `publish.rbac_refanned_at`.

**Legacy branch:** Agents with `identity == null` still print the existing `teamsapp` runbook from [foundry-teams-workiq/SKILL.md § Channel publishing](.apm/skills/foundry-teams-workiq/SKILL.md#channel-publishing--post-deploy-steps-print-to-user). When the upstream upgrade gesture for legacy → new agents GAs (currently "Coming soon" per MS Learn), this branch drops — tracked under quarterly verification.

**Original gap (largely obsoleted upstream):** `foundry-teams-workiq` SKILL printed the `teamsapp` CLI commands to build a Teams app .zip but did not execute them.

**Why obsoleted:** Foundry portal vNext (Early Access Preview) ships a **Direct Publish to Teams / M365 Copilot** button that auto-creates the Azure Bot Service resource and dispatches the M365 admin approval workflow. For agents on the new agent object model (`agent.identity != null`), the manifest-packaging chore that TD-2 was scoped to handle is no longer the customer-facing problem. ([MS Learn: Publish agents to Microsoft 365 Copilot and Microsoft Teams](https://learn.microsoft.com/azure/foundry/agents/how-to/publish-copilot))

**New gap declared (the surface widened, not narrowed):** Publishing flips the agent's runtime identity from the project identity to a new application identity. MS Learn (verbatim): *"Plan for identity changes when you publish. Tool calls authenticated by agent identity use the application identity after publishing, not the project identity."* ([Publish your agent as an Agent Application](https://learn.microsoft.com/azure/foundry/agents/how-to/agent-applications)) Every RBAC grant `/configure-rbac` made pre-publish breaks unless re-fanned. This is the new TD-2-shaped problem.

**Close-out (new):** Ship a `/publish-teams` prompt that handles the broader publish event:
1. Detect new vs legacy agent object model (`agent.identity` null check).
2. Legacy path: keep existing `teamsapp` runbook until the upstream upgrade gesture ships ("Coming soon" per MS Learn).
3. New path:
   - Preflight `Microsoft.BotService` provider registration in the subscription.
   - Configure Activity protocol + BotService / BotServiceRbac authorization scheme on `agent.yaml` (required for M365/Teams publish per MS Learn).
   - Detect BYO-VNet ↔ public Bot Service mismatch.
   - Scan publish metadata (display name, descriptions, URLs) for accidental secrets — MS Learn explicitly warns.
   - Gate publish on `/setup-evals` pass + `/setup-purview` middleware presence.
   - On post-publish: `/configure-rbac --post-publish` to re-fan the RBAC matrix from project identity to the new application identity.
   - Capture publish event as a delta in `agent-status.json` for `/audit-drift`.
   - Emit M365 admin approval runbook for "People in your organization" scope (admin center URL + paste-ready Teams message for the admin).

**Verification (track quarterly):** Re-check MS Learn for the legacy-agent upgrade gesture GA — once shipped, drop the legacy-path branch.

**Deck revisit required after merge:** Update Approach A Slide 4 — move Teams items from the ⚠ hand-off list into the ✓ orchestration list with implementation evidence. Update Approach B Slide 5 Card 2 to reference the shipped `/publish-teams` prompt (not "roadmap"). Update `00-objective-and-problem.md` open-in-flight to mark `/publish-teams` shipped.

## TD-3 — WorkIQ "is agent registered" check is beta API

**What:** `/verify-agent` uses `GET https://graph.microsoft.com/beta/admin/people/agents` to confirm Agent 365 inventory.

**Why:** No GA endpoint exists yet for programmatic Agent 365 inventory.

**Close-out:** Replace with GA endpoint when available (track Graph release notes).

## TD-4 — Foundry-native DLP is preview-limited (PARTIAL CLOSE in v0.16.0)

**What:** `purview.dlp.enabled: true` in the capabilities manifest prints a hard warning and stops; full SIT scanning + label enforcement requires Purview SDK middleware which is not part of this package.

**Status (v0.16.0):** Partially closed by shipping the **Layer 1.5 Purview DLP middleware** under [foundry-guardrails/purview-dlp.md](.apm/skills/foundry-guardrails/purview-dlp.md) + [scripts/purview_dlp_middleware.py](.apm/skills/foundry-guardrails/scripts/purview_dlp_middleware.py). The middleware:
- Calls Purview classification API per turn (input + response, optionally tool results).
- Acts on the verdict per `enforcement_mode`: `audit_only` | `warn` | `block`.
- Defaults to `audit_only` (always safe, fail-open on classifier errors).
- Requires explicit `AGREE_PURVIEW_DLP_PREVIEW=1` env var to start in `block` mode (constructor refuses without it).
- Emits structured OTel spans (`guardrail.purview_dlp.*`) for KQL + dashboards.

**Why not full close:** Three preview-grade gaps remain that require Purview-side GA:
1. **Token surface uncertainty.** The Purview classification API may require a Compliance-Admin-tier token for some tenants. Middleware uses `DefaultAzureCredential`; if your tenant requires elevated rights, you accept the risk of the secret in agent env vars.
2. **Label propagation through OBO.** Sensitivity labels in source documents only appear in classification responses when the source surfaces them via OBO (M365 path). For Foundry-hosted with `acl_passthrough: false`, only labels embedded in the prompt/response text are detected.
3. **API shape stability.** The `/classify` endpoint shape is preview-adjacent. If the shape changes, the middleware's `_classify` method needs swapping (rest of the middleware is shape-agnostic).

**Close-out:** Re-validate against Purview GA docs (daily docs scan flags surface changes); promote to full close when (1)–(3) above resolve.

## TD-5 — `apm.yml` has no `repository:` cross-link to skills

**What:** Skills do not declare individual `repository:` URLs; they share the package's.

**Why:** APM does not require it.

**Close-out:** Add `repository:` to each skill front-matter when the package crosses 1.0.

## TD-6 — No CI gate runs `apm install` against external consumer projects

**What:** `.github/workflows/apm-install-test.yml` validates the package resolves but does not validate that a typical consumer project can `apm install` + `apm compile -t copilot` cleanly.

**Close-out:** Add a `consumer-smoke` matrix job that creates a fresh repo, declares this package as a dep, and runs `apm install` + `apm audit` + `apm compile`.

## TD-7 — Agent identity propagation timing is not handled gracefully

**What:** Several gates note "RBAC propagation: 5–15 minutes" but `/verify-agent` runs immediately after `/configure-rbac`, often hitting 403.

**Close-out:** Add `--wait-for-rbac` flag that polls a known endpoint until success or 20 min timeout, with backoff.

## TD-8 — `azure-ai-projects` SDK surface drift

**What:** The `foundry-evals/scripts/ensure_*.py` wrappers call `evaluation_rules.create_or_update`, `schedules.create_or_update`, `red_teams.create`, and several model classes (`EvaluationRule`, `ContinuousEvaluationRuleAction`, `EvaluationRuleFilter`, `ProjectsSchedule`, `RecurrenceTrigger`, `EvaluationScheduleTask`, `RedTeam`, `AzureAIAgentTarget`) that are still moving in the preview SDK. Each script defensively falls back to the older `.create` surface when `.create_or_update` is missing, but new method renames will break us.

**Why deferred:** Foundry observability + red-team SDK is in active preview. Wrapping it now is the right call for audit-trail-in-Foundry, but we accept maintenance.

**Close-out:** A daily docs scan (Microsoft Learn MCP + Context7) flags the canonical method names; CI re-runs the wrappers against `azure-ai-projects` `latest` and pinned. Bump the pin window in `_common.py` + README in lockstep.

## TD-9 — Cloud red-team region list is hard-coded

**What:** [foundry-evals/scripts/ensure_redteam.py](.apm/skills/foundry-evals/scripts/ensure_redteam.py) caches `SUPPORTED_REGIONS` (refreshed 2026-06-15: `eastus2, northcentralus, francecentral, swedencentral, switzerlandwest, australiaeast`). This set churns as the preview expands and the list **moved doc** — it is no longer in the red-team how-to; the authoritative source is now [Rate limits, region support, and enterprise features for evaluation](https://learn.microsoft.com/azure/ai-foundry/concepts/evaluation-regions-limits-virtual-network) (§ *Risk and safety evaluators and AI red teaming region support*).

**Scope correction:** Only cloud **red-team + hosted risk/safety evaluators** are region-limited. **Batch/quality evals (continuous + scheduled) are broadly available (~30 regions incl. `westus`)** and are intentionally NOT region-gated. Don't conflate the two.

**Why deferred:** No public API exposes the supported region set programmatically.

**Mitigation (v0.27.x):** The gate is now advisory, not a wall — `ensure_redteam.py` bypasses the cached set under `--dry-run` or `REDTEAM_ALLOW_UNSUPPORTED_REGION=1` and defers to the live service. The doc is tracked as `priority: P0` in `maintenance/watch/doc-sources.yaml` (id `evaluation-regions-limits`), so each automation run re-verifies it — see `maintenance/foundry-dependency-map.md` § *Per-run freshness priorities*.

**Close-out:** Docs-watch diff on the `evaluation-regions-limits` P0 source updates the constant via PR.

## ~~TD-10 — Network detection scripts don't walk NSGs / Azure Firewall / SEPs~~ **(CLOSED in v0.20.0)**

**Status (v0.20.0):** Closed via the three-layer opt-in path documented in the close-out spec below.

**Shipped:**
- **Layer 1 — Deep walkers** (opt-in via `--deep`):
  - [scripts/network/deep-walk-nsg.sh](.apm/skills/foundry-prod-readiness/scripts/network/deep-walk-nsg.sh) — declared NSG rules + best-effort effective rules via `az network nic list-effective-network-security-rules`.
  - [scripts/network/deep-walk-firewall.sh](.apm/skills/foundry-prod-readiness/scripts/network/deep-walk-firewall.sh) — both classic application-rule collections and policy-based `ruleCollectionGroups`; FQDN-tag hints emitted.
  - [scripts/network/check-service-endpoint-policy.sh](.apm/skills/foundry-prod-readiness/scripts/network/check-service-endpoint-policy.sh) — flags SEP blocks on Foundry / Storage / AI Search service tags.
  - [scripts/network/check-source-network.sh](.apm/skills/foundry-prod-readiness/scripts/network/check-source-network.sh) extended with `--deep <agent_subnet_id> [<firewall_id>] [<fqdn>...]` to cascade the three walkers.
  - [`/prepare-deploy`](.apm/prompts/prepare-deploy.prompt.md) extended with `deep_network` input that wires `--deep` into the per-source loop.
- **Layer 2 — BYO VNet hand-off:** [scripts/network/templates/byo-vnet-with-pe.bicep](.apm/skills/foundry-prod-readiness/scripts/network/templates/byo-vnet-with-pe.bicep) — paste-ready VNet + delegated subnet + PE + Private DNS scaffold for `azd up`. The scripts emit a pointer to this file when `publicNetworkAccess=Disabled` and no PE is present.
- **Layer 3 — Troubleshooter runbook:** [foundry-prod-readiness/network-troubleshooter.md](.apm/skills/foundry-prod-readiness/network-troubleshooter.md) — symptom-triage table, full deep-walk command examples, DNS-from-Bastion fallback, and re-baseline command for `agent-status.json`.
- [networking.md](.apm/skills/foundry-prod-readiness/networking.md) "What the detection scripts deliberately leave to humans" section refreshed — Layer 1 now covered; remaining out-of-scope items (provisioning, cross-tenant peering, agent-side DNS) explicitly listed.

**Original gap:**

**What:** [foundry-prod-readiness/scripts/network/check-source-network.sh](.apm/skills/foundry-prod-readiness/scripts/network/check-source-network.sh) checks `publicNetworkAccess`, `networkAcls.defaultAction`, IP / VNet rule counts, and PE count — then prints "if NSG/Firewall is in place, verify outbound 443 manually".

**Why deferred:** Walking NSG rule chains, Azure Firewall application rules, and Service Endpoint Policies is high-maintenance and tenant-shape-specific. Most silent failures are caught by the four checks above + private DNS linkage; the residual is best handled by a human eyeball.

**Close-out (PR-ready spec, three layers):**

1. **Opt-in `--deep-network` flag** on `/prepare-deploy` (default off; slow path 60–120 s typical):
   - New script `scripts/network/deep-walk-nsg.sh <subnet-id>` — walks NSG rules on the agent's subnet *and* the source workload's subnet via `az network nic list-effective-network-security-rules`; checks outbound 443 against the canonical Foundry / source FQDNs declared in `agent-capabilities.yaml`.
   - New script `scripts/network/deep-walk-firewall.sh <firewall-id>` — enumerates Azure Firewall application rules via `az network firewall application-rule list` if a Firewall is detected in the route path.
   - New script `scripts/network/check-service-endpoint-policy.sh <subnet-id>` — `az network vnet subnet show --query serviceEndpointPolicies` to flag SEP blocks on Foundry / Storage / AI Search service tags.
   - Wire the three into `check-source-network.sh` behind a `--deep` flag so callers can keep the fast path by default.

2. **Known-good Bicep snippet emission** (closes the "detect → recommend → hand off" gap):
   - New file `scripts/network/templates/byo-vnet-with-pe.bicep` — minimal VNet + Private Endpoint + Private DNS zone in a known-good configuration for Foundry.
   - `check-source-network.sh` prints "drop this snippet into `./infra/main.bicep` and re-run `azd up`" when detection finds BYO VNet without a working PE. We don't run `az network create`; we hand off a paste-ready artifact.

3. **`network-troubleshooter.md` runbook** (converts unknown failures → known failure modes):
   - New doc `foundry-prod-readiness/network-troubleshooter.md` — step-by-step: "agent returns 503" → identify network class via `check-foundry-network-mode.sh` → re-run `check-source-network.sh --deep` → manual `curl` / `nslookup` from a Bastion host → link to the right Azure portal blade.
   - Cross-link from `foundry-prod-readiness/SKILL.md` failure-mode index and from the runbook-emit script.

**Trigger:** Multiple users hit silent NSG-block failures (was: "only if"); now elevated because Approach A Slide 4 of the exec deck claims this work; we should ship it on the same release that the deck is presented.

**Deck revisit required after merge:** Update Approach A Slide 4 ⚠ hand-off list — move "Network: VNet / PE / NSG provision" out of the ⚠ column for the `--deep` path; keep the runbook hand-off framing for the provision step. Update `00-objective-and-problem.md` validated facts to drop "network scripts are read-only detection only" once the `--deep` flag ships (note still applies to provisioning).

## TD-11 — ~~`agent-status.json` durable state is not yet implemented~~ (CLOSED in v0.11.0)

**What:** Per-agent durable record of identities, RBAC outcomes, network detection results, eval rule IDs, verify outcomes, and capability-hash baselines for drift detection.

**Status:** Closed in v0.11.0. Schema in [foundry-deploy/agent-status-schema.md](.apm/skills/foundry-deploy/agent-status-schema.md), helper in [foundry-deploy/scripts/agent_status.py](.apm/skills/foundry-deploy/scripts/agent_status.py). Three readers wired:
- `/prepare-deploy` — init + stamp `preflight` + `network` + baseline `drift.capability_hash_at_preflight`
- `/configure-rbac` — stamp `identities` + `rbac.phases_completed` + `rbac.capability_grants` + `rbac.pending` + re-baseline `drift.capability_hash_at_rbac`
- `/verify-agent` — drift check at Step −1, stamp `deploy` + `verify`

**Follow-ups (open as separate TDs when prioritized):**
- `/audit-drift` prompt (TD-12, planned) — 4th reader, surfaces declared-vs-observed deltas without mutating.
- Helper-side schema validation tightening (currently loose: section names enforced, fields free) when churn warrants — bump `schema_version` and ship a migration.

## TD-12 — ~~`/audit-drift` prompt~~ (CLOSED in v0.17.0)

**What:** Read-only declared-vs-observed reconciler. Walks `agent-capabilities.yaml` + the live world (Azure RBAC, Foundry connections, eval rules, Purview toggle, network class) and emits a markdown delta report. Never mutates.

**Status:** Closed in v0.17.0. Implementation: [.apm/prompts/audit-drift.prompt.md](.apm/prompts/audit-drift.prompt.md) (single prompt, no new scripts). Forward + reverse drift detection. Stamps `agent-status.json` `verify` block with `last_audit_at`, `audit_summary`, `audit_report_path` (additive — doesn't replace `/verify-agent`'s fields).

**Operational integration:**
- Documented in [recipes/02-brownfield-onboarding.md](../foundry-agent-playbook/.apm/skills/foundry-agent-playbook/recipes/02-brownfield-onboarding.md) Step 9 as the recommended weekly maintenance task.
- Designed for non-blocking CI scheduling — not a PR gate. (`/verify-agent` is the PR gate.)

## TD-13 — Brownfield code scan is regex-only (acceptable trade-off, tracked for visibility)

**What:** [foundry-knowledge/scripts/scan_knowledge_refs.py](.apm/skills/foundry-knowledge/scripts/scan_knowledge_refs.py) uses line-level regex against Python source files — not AST, not framework introspection. Misses: same-line aliased imports (`from azure.search.documents import SearchClient as SC`), conditional imports inside try/except, framework-specific tool registration patterns we don't have a regex for.

**Why this trade-off:** Per the agreed design, code scan is a *signal* not a source of truth — the scan always asks the user to confirm/edit, never silently classifies. AST-based scanning is a 5x complexity jump for marginal recall gain.

**Close-out:** Add an optional `--ast` flag using `ast` + framework-specific visitors only when (a) we hit multiple users with false negatives, or (b) we add support for a framework whose patterns are too dynamic for regex (e.g., DSPy).

## TD-14 — External persistence for Invocations agents (PLANNED — next-version roadmap)

**What:** Invocations-protocol hosted agents (webhook receivers, AG-UI streamers, batch processors) get NO platform-managed conversation history. The platform persists `agent_session_id` sandbox state for up to 30 days with a 15-minute idle timeout, but anything beyond that — cross-session user preferences, durable workflow state, multi-month chat histories — is the agent's responsibility.

**Why this matters now (and not for Responses):** Responses-protocol agents get `previous_response_id` / `conversation` autobind for free; the platform stores message history server-side. Invocations agents don't — because the payload shape is arbitrary, the platform can't infer what "history" means.

**Why deferred:** Three patterns that need separate sub-docs and per-pattern grant scripts (Cosmos DB, Redis, Storage Tables). Each requires capability-manifest schema extension (`persistence` block) + Phase A preflight + Phase B grants + Phase C verify. Full close is 5–7 files; not in scope for v0.16.0.

**Close-out plan (next-version roadmap):**
1. New sub-doc `foundry-deploy/external-persistence.md` covering decision matrix (do you actually need this?) + Cosmos / Redis / Storage Tables patterns + anti-pattern of treating `$HOME` as durable.
2. Schema extension: `persistence` block in `agent-capabilities.yaml` (optional; only declared by Invocations agents).
3. Per-store Phase B grant scripts under `foundry-deploy/scripts/persistence/` (or a new `foundry-state` skill if patterns grow).
4. `/configure-rbac` dispatch: Phase B grant per declared store (Cosmos data-plane role, Storage Blob Data Contributor, etc.).
5. `/verify-agent` Phase C: read/write a sentinel item end-to-end.

**Note:** This is distinct from the (also unscoped) `register-custom-agent` flow, which is for agents *running entirely outside Foundry* with Foundry just providing monitoring/eval. That's its own potential future skill (`foundry-control-plane` or similar).

## TD-15 — Microsoft Learn submission (PLANNED — post-1.0)

**What:** Submit the skillpack's content to Microsoft Learn (`learn.microsoft.com/azure/foundry/...`) for inclusion in the official Foundry hosted-agent documentation surface. Today this content is community-published via Astro Starlight + Azure Static Web Apps; Microsoft Learn would put it in the same place dev teams already look for Azure docs.

**Why deferred:** Microsoft Learn submission is a months-long process: content review, IP review, branding review, Microsoft assuming ownership of the URL and editorial cadence. It's the right destination eventually but not the right destination *yet* — the skillpack is iterating quickly against a preview-adjacent Foundry surface, and the Learn submission process trails active development by 6–12 months.

**Close-out plan (post-1.0):**
1. Wait until adoption justifies the submission cost (e.g., ≥ 100 stars, ≥ 5 distinct organizations using in production).
2. Identify a Microsoft sponsor for the submission (Foundry product team or Azure Apps + AI DX).
3. Author submission package: content, IP attestation, brand alignment.
4. Negotiate which content lives where (some content stays on the docs site as community extension; some moves to Learn as canonical).
5. Set up redirects from `foundry-agent-skillpack.example.com` to the Learn URLs for migrated pages.

**Until then:** the Astro Starlight site at `docs/` is the canonical render.

## TD-16 — Per-capability requirements snippets (PLANNED — when users complain)

**What:** Today, container-side Python dependencies needed per declared capability live in a single table in [foundry-deploy/runtime-dependencies.md](.apm/skills/foundry-deploy/runtime-dependencies.md). The user must read it, cross-reference their `agent-capabilities.yaml`, and manually append the right lines to their `requirements.txt`.

**Why deferred:** v0.18 ships with the single-page table because (a) it's enough for the current user count and (b) any automation that mutates user code is a stronger boundary than the skillpack has crossed. The cheap fix wins until real users complain.

**Close-out plan (when triggered):**
1. Per-capability `requirements-snippet.txt` files under each skill's `scripts/` folder (e.g., `foundry-guardrails/scripts/requirements-snippet.txt`, `foundry-knowledge/scripts/requirements-snippet.txt`).
2. New helper `foundry-deploy/scripts/inject-requirements.sh` — given an `agent-capabilities.yaml`, **prints** the lines to append (never mutates the user's file). Pattern: same posture as `runbook-emit.sh` — emit a paste-ready block.
3. `/prepare-deploy` Track H3 gate reports a delta: declared capabilities vs `requirements.txt` content; suggests the helper.
4. Document in `runtime-dependencies.md` § "How to update your existing requirements.txt".

**Triggers to start work:**
- Multiple users miss a runtime dep at deploy time (e.g., `ModuleNotFoundError` after `azd up`).
- A new capability is added that has non-obvious deps (TD-14 external persistence is a likely trigger).

## TD-17 — Docs site drift from skillpack sources (PHASE 1 SHIPPED in v0.18.0; Phase 2 post-1.0)

**What:** The docs site (`docs/src/content/docs/`) is a **curated subset** of the skillpack's skill content, not a mirror. Today:
- **Recipes** are mirrored automatically (`docs/scripts/mirror-recipes.mjs` runs on every dev/build).
- **Skills, prompts, TECHNICAL_DEBT, concept pages** are hand-curated and drift from the underlying sources.

**Why this matters:** small skill-level changes get made without updating the docs site, so the published documentation lags the actual skillpack behavior over time.

**Why a full mirror isn't the right answer (yet):**
- Skills are written for an LLM's context window (terse routers + sub-docs). Verbatim rendering on a docs site gives wall-of-text pages.
- Curated concept pages (`what-is-this.md`, `lifecycle.md`, etc.) are higher-quality than a raw skill mirror would produce.
- Heterogeneous skill shapes mean the mirror script would need per-skill rules.

**Status:**

*Phase 1 — Drift check script (SHIPPED in v0.18.0).*

Implementation:
- [`docs/scripts/check-drift.mjs`](../docs/scripts/check-drift.mjs) — set-difference check across three surfaces:
  - Skills directory ↔ `docs/src/content/docs/skills.md` table.
  - Prompts directory ↔ `docs/src/content/docs/reference/prompts.md`.
  - `TECHNICAL_DEBT.md` `## TD-N` entries ↔ `docs/src/content/docs/technical-debt.md` table.
- CI integration in `.github/workflows/docs.yml`: a `Check for docs ↔ skillpack drift` step that runs before the build, emits the report to `$GITHUB_STEP_SUMMARY`, and is non-blocking (`continue-on-error: true`). PR reviewers see the report on the workflow run page.
- Output format: markdown report with ✅ / ⚠ per surface, plus a summary count.
- Exit code: always 0. The script is a nag, not a gate. By design.

What it deliberately doesn't do:
- No content-equality check. Paraphrased prose between source and docs is the whole point of a curated docs site; flagging every difference would be noise.
- No auto-fix. Drift is a human-review concern.
- No block-on-drift. PR authors get a heads-up; reviewer + author decide whether to update.

*Phase 2 — Mirror script for skills (post-1.0).*
1. `docs/scripts/mirror-skills.mjs` that mirrors **SKILL.md routers only** (not sub-docs) into `docs/src/content/docs/skills/<name>.md`.
2. Sub-docs continue to live in the skillpack; the docs-site skill page links to them on GitHub.
3. Curated concept pages stay hand-written — they're not mechanical mirrors.

**Operational note:** when you add or rename anything in `foundry-agent-skillpack/.apm/skills/`, the drift check will flag the gap in the next PR. Update the matching docs page (`skills.md`, `reference/prompts.md`, or `technical-debt.md`) in the same PR to close it.

## TD-18 — Foundry MCP lacks native `model_deployment_list` (OPEN — mitigated)

**What:** The Foundry MCP server exposes per-name `mcp_foundry_mcp_model_deployment_get` (returns 404 if the deployment is absent) but no list-by-account endpoint. `/plan-agent` Step 0b and `/prepare-deploy` Step 2.4 need to enumerate existing deployments in `target.foundry_account` to render a picklist.

**Status (mitigated, v0.19.0):** The skillpack routes through `mcp_azure_mcp_foundry` (action: `deployments.list`) for the enumeration call, then continues to use `mcp_foundry_mcp_model_deployment_get` for per-name validation and `mcp_foundry_mcp_model_deploy` for create. This split is documented in [foundry-deploy/model-selection.md](.apm/skills/foundry-deploy/model-selection.md) Step 1, with the rationale explicitly noted so future maintainers don't try to "consolidate" by hand-rolling REST calls.

**Why not full close:** Going through Azure MCP introduces a second tool dependency for what should be a single-MCP capability. It's a maintenance footnote, not a user-facing problem — both tools are stable and shipped.

**Close-out:** When Foundry MCP ships `mcp_foundry_mcp_model_deployment_list` (or equivalent), swap the call site in `model-selection.md` Step 1 and remove the cross-reference. One-file change. Track Foundry MCP release notes via the daily docs scan.

## TD-19 — Package rename `foundry-agent-harness` → `foundry-agent-skillpack` (OPEN — alias active)

**What:** v0.19.0 renames the package directory and all references from `foundry-agent-harness` to `foundry-agent-skillpack` (the second rename in this package's history; v0.18.0 was `engineering` → `harness`). To avoid breaking external consumers' `apm.yml dependencies:` blocks immediately, v0.19.0 ships `aliases: [foundry-agent-harness]` so `apm install` resolves the old name through the new package.

**Why deferred close:** The alias is a one-release courtesy. Keeping it forever would (a) leave two valid names in tooling output (`apm list` etc.), (b) keep stale references in consumer search results, and (c) blur the canonical name in support conversations.

**Consumer migration (one-line edit):**

```diff
 dependencies:
   apm:
-    - sathik11/foundry-agent-skillpack/foundry-agent-harness
+    - sathik11/foundry-agent-skillpack/foundry-agent-skillpack
```

The GitHub repo was also renamed from `Foundry-Hosted-Agent-Skill` to `foundry-agent-skillpack` in v0.20.0. GitHub auto-redirects old URLs, so existing clone URLs, raw-file links, and PR/issue history continue to work.

**Close-out:** Remove the `aliases:` line from `foundry-agent-skillpack/apm.yml` in v0.24 (deferred past v0.23.0 so the alias survives the TD-24/25 close-out release). Bump major-or-minor per usual policy. Add a final-warning note to the release notes pointing here.

## ~~TD-23 — Inbound firewall coverage for Teams / M365 Copilot → private Foundry agent~~ **(CLOSED in v0.22.0)**

**Status (v0.22.0):** Closed. The published-bot silent-fail mode (typing indicator → no reply) on private Foundry accounts is now covered end-to-end by:

- [foundry-teams-workiq/inbound-firewall.md](.apm/skills/foundry-teams-workiq/inbound-firewall.md) — 8-section runbook covering the architecture, decision matrix across APIM v2 / YARP / AppGW+APIM, paste-ready `<validate-jwt>` policy with verbatim `login.botframework.com` OIDC config, prereqs checklist (Key Vault-backed cert because v2 tiers don't support free managed cert, plus the Microsoft-suspended-through-2026-06-30 status), firewall worksheet, 3-probe verification, 6-row failure-mode table, anti-patterns.
- [foundry-teams-workiq/scripts/templates/apim-v2-vnet-integrated.bicep](.apm/skills/foundry-teams-workiq/scripts/templates/apim-v2-vnet-integrated.bicep) — paste-ready Bicep scaffold for APIM StandardV2 + outbound VNet integration + custom domain (KV-backed cert) + the API/operation/policy/product wiring. `@allowed` constrains SKU to `StandardV2` / `PremiumV2` (BasicV2 explicitly NOT supported for VNet integration per MS Learn). Subnet delegation `Microsoft.Web/serverFarms`. Outputs include the messaging endpoint URL the operator pastes into Bot Service.
- [foundry-teams-workiq/scripts/render-apim-policy.sh](.apm/skills/foundry-teams-workiq/scripts/render-apim-policy.sh) — emits the canonical inbound policy XML for non-Bicep deploys; `--inline` mode substitutes APIM named-value placeholders with concrete values from `agent-status.json` + `agent-capabilities.yaml`. Policy XML is byte-identical to the Bicep `<policies>` block and the canonical block in `inbound-firewall.md` (three sources, one truth).
- [foundry-teams-workiq/scripts/probe-inbound-chain.sh](.apm/skills/foundry-teams-workiq/scripts/probe-inbound-chain.sh) — 3-probe verifier (TLS smoke / missing-auth 401 / synthetic-invalid-JWT 401). On full pass with `--stamp`, writes `publish.inbound_chain` into `agent-status.json` (custom FQDN, backend URL, probe timestamp, verdict).
- Additive `publish.inbound_chain` block in [agent-status-schema.md](.apm/skills/foundry-deploy/agent-status-schema.md#publish--written-by-publish-teams-and-configure-rbac---post-publish-td-2) v1.2 (no `schema_version` bump — additive only; `agent_status.py` `ALLOWED_SECTIONS` already contains `"publish"`).
- New Step 0a in [`/publish-teams`](.apm/prompts/publish-teams.prompt.md) branches on `network.class == "byo_vnet"` OR Foundry `publicNetworkAccess == "Disabled"` and prints the inbound-firewall.md handoff banner before preflight. The `BYO_VNET_PUBLIC_BOT_MISMATCH` gate in `preflight-publish.sh` now has a documented exception path: stand up the inbound chain → override with rationale.
- Cross-skill callouts: [foundry-prod-readiness/networking.md § Inbound](.apm/skills/foundry-prod-readiness/networking.md#inbound--teams--m365-copilot--private-foundry-agent) explains why `Bot Service "Public Access disabled"` only blocks Direct Line (not the Channel Adapter that delivers Teams messages); the firewall allowlist table gains `smba.trafficmanager.net` + `login.botframework.com` for the outbound reply path. [foundry-prod-readiness/network-troubleshooter.md § Symptom triage](.apm/skills/foundry-prod-readiness/network-troubleshooter.md#symptom-triage) routes the silent-typing symptom to inbound-firewall.md. [foundry-failure-modes/SKILL.md F-20](.apm/skills/foundry-failure-modes/SKILL.md#publish--channel-failures) documents the inbound + outbound legs of the silent failure.

**Original gap:** Foundry accounts with `publicNetworkAccess=Disabled` (BYO VNet or managed VNet "Allow only approved") publish cleanly to Teams via `/publish-teams`. The Bot Service messaging endpoint accepts a URL but does not validate it can be reached from the Bot Framework Channel Adapter's public-backbone IPs (Teams service tag `52.112.0.0/14`, `52.122.0.0/15`). The Channel Adapter then drops activities silently when it cannot reach the registered endpoint. Operators saw: `@mention` succeeded, typing indicator appeared, reply never came; no error in Foundry traces, no entry in App Insights, no 4xx anywhere obvious. The publish itself stayed green because Bot Service's "Test in Web Chat" hits Direct Line (a separate REST path that was never blocked) — a textbook silent-fail mode.

**Why now:** Two community write-ups raised the visibility (Matt Felton on the silent-publish-success symptom; Graeme Foster on the outbound reply FQDN allowlisting requirement under managed VNet "Allow only approved"). The fix surface is small (one doc + one Bicep + two scripts + 4 callouts) and the closure is hard-mechanical (probe script returns non-zero on any of the three failures), so the gap was promoted from "open in roadmap" to v0.22.0 close-out.

**Close-out completed:**
- ✅ `inbound-firewall.md` shipped (~280 lines, 8 sections)
- ✅ `apim-v2-vnet-integrated.bicep` shipped (StandardV2 default, PremiumV2 allowed; Key Vault cert path)
- ✅ `render-apim-policy.sh` shipped (placeholder mode + `--inline` substitution)
- ✅ `probe-inbound-chain.sh` shipped (3 probes + optional `--stamp` writes to agent-status)
- ✅ `agent-status-schema.md` v1.2 additive `publish.inbound_chain` (no schema_version bump)
- ✅ `/publish-teams` Step 0a inbound-chain branch
- ✅ `networking.md` Bot Service asymmetry callout + reply-path allowlist entries
- ✅ `network-troubleshooter.md` symptom triage entry
- ✅ `foundry-failure-modes/SKILL.md` F-20 + quick-triage row

## ~~TD-24 — api-version drift in `az rest` calls~~ **(CLOSED in v0.23.0)**

**Original gap:** Three `az rest --method get` calls in scripts and one in prose were pinned to api-versions that ARM no longer accepts (or that were never GA). The dominant failure pattern was `--query` / `--uri` calls wrapped in `|| echo '{"value":[]}'` so an ARM `Not Found(InvalidResourceType)` response was silently rewritten to an empty result, never surfaced to the operator.

| File:line | Pinned (before) | ARM verdict | Bumped to |
|---|---|---|---|
| [discover-target.sh:67](.apm/skills/foundry-deploy/scripts/discover-target.sh) | `2024-10-01` | ❌ rejected (`accounts/projects` resource type not in that api-version's manifest) | `2026-03-01` (current GA) |
| [check-identities.sh:16](.apm/skills/foundry-identity/scripts/check-identities.sh) | `2025-04-01-preview` | ⚠ preview pin (still works but unstable) | `2026-03-01` (current GA) |
| [check-service-endpoint-policy.sh:59](.apm/skills/foundry-prod-readiness/scripts/network/check-service-endpoint-policy.sh) | `2024-05-01` | ⚠ 1-year-old GA | `2025-07-01` (current GA) |
| [deep-walk-firewall.sh:49](.apm/skills/foundry-prod-readiness/scripts/network/deep-walk-firewall.sh) | `2024-05-01` | ⚠ 1-year-old GA (`firewallPolicies/ruleCollectionGroups` latest is 2025-09-01) | `2025-09-01` (current GA) |
| [two-identities.md:15](.apm/skills/foundry-identity/two-identities.md) (prose) | `2025-04-01-preview` | ⚠ preview pin in copy-paste example | `2026-03-01` (current GA) |

Verification: `az provider show -n Microsoft.CognitiveServices --query "resourceTypes[?resourceType=='accounts/projects'].apiVersions"` was the source-of-truth for the bumps. The discover-target.sh failure was reproduced on a live RG (returned blank `PROJECT_NAME=`), then verified fixed end-to-end (now returns the correct project).

**Why this kept slipping:** `|| echo '{"value":[]}'` and `2>/dev/null || echo "[]"` are everywhere in these scripts. They're defensible (discovery should be best-effort, no crash on a missing sub-resource), but they also swallow api-version drift errors that look identical to "the resource doesn't exist." See TD-27 for the structural prevention.

**Close-out completed:**
- ✅ 4 api-version bumps landed (3 scripts + 1 prose)
- ✅ discover-target.sh now captures stderr explicitly: on `az rest` non-zero exit, logs `[!] Projects API failed for <acct> (rc=N). Bump api-version or check RBAC.` followed by the first 240 chars of the response — visible failure mode instead of silent empty-result
- ✅ Verified against a live multi-account RG: `DISCOVERY_STATUS=complete`, project + deployments correctly returned

**Out of scope (tracked separately):** the other two scripts still use the silent `|| echo '[]'` pattern. Whether to convert them to the explicit-stderr-capture pattern is TD-27's call (a registry of api-versions would let us source the version + have a single error-handling helper).

## ~~TD-25 — `discover-target.sh` enumerated sub-resources only for account [0]~~ **(CLOSED in v0.23.0)**

**Original gap:** Inside the `if (( ACCOUNT_COUNT > 0 ))` branch, the script pulled `jq -r '.[0].name'` for the primary account and then queried projects + deployments **only** for that account. Accounts [1..N] were emitted as `FOUNDRY_ACCOUNT_NAME_2=`, `_3=` (name-only) but their sub-resources were never enumerated.

Failure mode (reproduced on `agents-3iq`, 3 accounts in one RG):

| | Ground truth | Script reported (before) | After fix |
|---|---|---|---|
| Projects | 2 (one per AIServices account) | 0 (combined with TD-24 silent failure) | 2 ✓ |
| Deployments | 19 (16 in eastus2, 3 in ncus-2) | 8 (acct #0 only) | 19 ✓ |
| `DISCOVERY_STATUS` | — | `partial` | `complete` |

**Close-out completed:**
- ✅ Replaced the single-account block with a `for i in $(seq 0 $((ACCOUNT_COUNT - 1)))` loop that iterates every AIServices account (`ContentSafety`, `OpenAI`-only, etc. are skipped — they don't have projects or agent-facing deployments)
- ✅ Account [0] still emits the un-suffixed primary keys (`FOUNDRY_ACCOUNT_NAME=`, `PROJECT_NAME=`, `MODEL_DEPLOYMENT_NAME=`) so downstream prompts keep working without changes
- ✅ Accounts [1..N] emit aggregate keys `ACCOUNT_<n>_PROJECT_NAMES=p1,p2` and `ACCOUNT_<n>_DEPLOYMENT_NAMES=d1,d2,d3` plus a stderr summary
- ✅ Bug-side effect of the previous nesting also fixed: deployments enumeration was previously nested inside the "project found" branch, so an account with deployments but no projects skipped deployment discovery entirely

**Trade-off:** Discovery is ~3s slower per additional AIServices account (the new per-account `az rest` + `az cognitiveservices account deployment list` calls run sequentially). On our 2-account test RG: 5.5s → 8.5s. TD-26 (Resource Graph hybrid) recovers this and goes faster than baseline.

## TD-26 — Resource Graph hybrid for `discover-target.sh` (OPEN — preventive)

**What:** `discover-target.sh` makes 4 sequential ARM round trips today (account list, projects REST, deployments list, ACR list). TD-25's per-account loop multiplies the projects + deployments calls by the number of AIServices accounts in the RG. A single `az graph query` against the `Resources` table can return accounts + projects + ACRs in one round trip with no api-version pin (ARG schema is centrally managed → eliminates the TD-24 class of bug for these three resource types).

**Verified via live PoC** (May 2026, against `agents-3iq`):

| Approach | Time | Round trips | Notes |
|---|---|---|---|
| Today (post-TD-25) | 8.5s | 1 + 2×(projects + deployments) sequential | correctness ✓, perf hit on multi-account RGs |
| Hybrid ARG + parallel fan-out | **2.0s** | 1 ARG query + N parallel `account deployment list` | 4.2× faster than current, 2.7× faster than pre-TD-25 baseline |

**Hard finding — ARG does NOT index everything:**
- ✓ indexed: `microsoft.cognitiveservices/accounts`, `accounts/projects`, `microsoft.containerregistry/registries`
- ✗ NOT indexed: `microsoft.cognitiveservices/accounts/deployments` (confirmed: ARG returned 0 globally despite 19 existing). Deployments still need one `az cognitiveservices account deployment list` per discovered AIServices account — fan-out in parallel with `&` + `wait`.

**Why not landed in v0.23.0:**
1. Requires the `resource-graph` az extension (not installed by default — verified on a clean machine). One-time `az extension add -n resource-graph` (~5s). Modern `az` auto-installs on first use, but corp policy can block extension install entirely. **Needs a fallback path to today's sequential `az` calls**, and that fallback must be verified on a tenant where extensions are policy-denied before we ship.
2. ARG is eventually consistent (~minutes after a fresh provisioning). For brownfield discovery this is non-issue; for post-`azd up` verification it can race. Fallback path also covers this.
3. The recently-shipped per-account loop (TD-25) is correct, just slower. Bug fix before performance fix.

**Close-out plan:**
- Add `_ensure_resource_graph()` helper to script: `az extension show -n resource-graph || az extension add -n resource-graph --only-show-errors`. On failure, set `USE_ARG=0` and log one line.
- One ARG query returns accounts + projects + ACRs in normalized form.
- Per-account parallel `az cognitiveservices account deployment list` calls (already in TD-25 just sequential — change `&` + `wait`).
- Preserve every emitted KEY=VALUE so downstream prompts don't break.
- No flag, no opt-in. ARG path is default; fallback is silent-on-success / one-stderr-line-on-fail.

## TD-27 — No central registry of api-versions (OPEN — preventive)

**What:** TD-24 fixed 4 silent-drift bugs that all stemmed from the same anti-pattern: api-version strings hand-written inline in `az rest --uri` calls, with errors caught by `|| echo '{"value":[]}'`. The fix bumped the strings; the structural problem (next year's GA bumps will silently re-introduce drift) stayed.

**Proposal:** A single sourced shell file with named constants — e.g. [.apm/scripts/_api-versions.sh](.apm/scripts/_api-versions.sh) (new):

```bash
# Last verified: 2026-05-25 via `az provider show -n <ns> --query resourceTypes`
export API_COGSVC_PROJECTS="2026-03-01"
export API_NETWORK_SERVICE_ENDPOINT_POLICIES="2025-07-01"
export API_NETWORK_FIREWALL_POLICY_RCG="2025-09-01"
export API_FOUNDRY_AGENTS_DATAPLANE="2025-05-01"
export API_SEARCH_DATAPLANE="2024-07-01"
export API_SEARCH_KNOWLEDGEBASES="2025-11-01-preview"  # preview-only feature, no GA yet
```

Plus a shared error-surfacing helper `_az_rest_capture()` that replaces `|| echo '[]'` with explicit stderr logging of the ARM error (the pattern TD-24's discover-target.sh fix introduced).

**Why not landed now:** Five scripts is below the threshold where the indirection cost wins. A registry pays off once we add the 6th or 7th `az rest` call (e.g. when TD-26 lands or when future skills add new ARM calls). Tracked here so we don't accidentally add a 6th hand-pinned api-version.

**Verification gate:** Add a CI step (or a `make verify-api-versions` target) that runs `az provider show -n <namespace>` for each constant and warns if the pinned version is no longer in the supported list. Catches future ARM deprecations before they hit operators.

**Out of scope:** Foundry data-plane and Search data-plane versions live in a different versioning track (service endpoints, not ARM RPs). They need their own verification — `microsoft_docs_search` queries against MS Learn, or a known-good probe call.

## TD-28 — Cross-OS script runtime — bash + pwsh dual-script bake-off (OPEN — v0.24 bake-off, v0.25 ship decision)

**What:** Every `.apm/skills/*/scripts/*.sh` in the skillpack is bash-only (28+ scripts, ~79 `az` invocations, ~104 `jq` invocations). Native Windows (PowerShell / cmd) cannot run them. Today's only Windows path is WSL2; Git Bash partially works but bites on path mangling, `python3` aliasing, and process substitution in multi-line `jq` pipelines.

**Why this is debt:** Foundry is a Microsoft product; the customer base skews Windows-enterprise. A skillpack that requires WSL2 for first use is architectural debt, not just a docs problem. Microsoft Learn itself maintains thousands of dual bash/pwsh code snippets — there is a working precedent we are not following.

**Token/time cost of the missing-script fallback (added 2026-06-25):** when a script is unavailable for the host OS (Windows, no `.ps1`) or fails to run, the agent does not stop — it silently falls back to driving the VS Code Foundry MCP tool directly, in a multi-call read/poll loop. That fallback is materially worse than a native script: it burns model tokens and wall-clock time on round-trips that a single deterministic script call would have collapsed, and it produces no greppable artifact for parity testing or review. The fallback loop is the *most expensive* failure mode of the bash-only posture and is the primary argument for native per-OS scripts over "the MCP will cover Windows." The bake-off success criteria below should explicitly include "eliminates the MCP-fallback loop on `windows-latest`," not just LOC/runtime parity.

**Why deferred from v0.23.0:** Needs a real bake-off, not a guess. v0.23.0 shipped the install script for the supported (macOS / Linux / WSL2) path and documented the gap honestly.

**Three options considered:**

| Option | Why considered | Why rejected for now |
|---|---|---|
| A. Parallel `.sh` + `.ps1` (this TD) | Native each OS · mirrors Microsoft Learn doc patterns · copy/paste from `learn.microsoft.com` works directly · `ConvertFrom-Json` is genuinely nicer than `jq` chains | Drift is real — but solvable with shared parity tests + CI gate. Worth bake-off. |
| B. Python SDK rewrite | Single source · type-checkable · faster runtime (no subprocess spawn) · aligns with `azure-ai-projects` we already require | SDK api-versions are hidden inside package versions (arguably worse drift than greppable bash). Preview APIs need `httpx` fallback (back to manual REST). Bigger migration. |
| C. Status quo + WSL2 docs | Zero cost | Ships debt forward to every new Windows consumer. |

**Bake-off plan (v0.24 — research only, no consumer-visible scripts shipped):**

1. **Install pwsh on the dev's machine.** Linux/Mac: pwsh 7.4+ runs cross-platform.
   ```bash
   # WSL2 / Ubuntu 24.04
   wget -q https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
   sudo dpkg -i packages-microsoft-prod.deb
   sudo apt-get update && sudo apt-get install -y powershell
   ```
2. **Port `discover-target.sh` to `discover-target.ps1`** as the bake-off candidate. Touches most of our patterns: `az rest`, JSON parsing, per-account loops, stderr capture, parallelism opportunity.
3. **Build `tests/parity/` harness** (the gate that prevents TD-24-style drift in a dual-script world):
   - `tests/parity/mocks/az` — fake `az` binary returning canned JSON from `fixtures/`
   - `tests/parity/run-parity.sh` — runs both implementations against mocked `az`, diffs `sort`ed output, exits non-zero on divergence
   - `tests/parity/live/verify-against-agents-3iq.sh` — optional live run (slower; needs auth)
   - `.github/workflows/script-parity.yml` — matrix `ubuntu-latest`, `macos-latest`, `windows-latest`
4. **Measure:** LOC delta, runtime, drift surfaces during port, copy-paste-from-Learn fidelity, Windows smoke pass.
5. **Decide based on data, not preference.** Possible outcomes:
   - Dual bash+pwsh wins → ship migrated hot-path scripts (8 scripts every prompt uses) in **v0.25**; long tail later.
   - Bake-off reveals divergence is unmanageable → close TD-28 in **v0.25** with the data, document why, stay with bash + WSL2 (Option C).
   - Bake-off reveals Python (Option B) is materially better than either → reopen with Python framing as TD-30 (note: shifted from previously planned TD-30 for compliance mapping; renumber if needed).

**Sequencing rationale:** TD-28 and TD-29 were both originally labeled "v0.24 candidate". They are independent work streams (different code paths, different reviewer brains) and bundling risks delivering neither well. **TD-29 (AGT integration) is firmed to v0.24** as the strategic-credibility release; **TD-28 bake-off runs as research during v0.24** and ships its decision in v0.25. No consumer-visible pwsh scripts ship until v0.25.

**Decision criteria for "dual wins":**
- pwsh port LOC within ~120% of bash baseline.
- Parity tests catch 100% of seeded divergences (we'll deliberately introduce 3-5 drifts during the bake-off and confirm CI fails).
- Windows smoke test on `windows-latest` runner passes.
- No more than 2 places needed OS-specific code (e.g. path separator handling).

**Decision criteria for "abandon dual":**
- pwsh port LOC > 200% of bash baseline.
- Windows surfaces non-trivial issues (e.g. `azd ai agent` CLI behaves differently, auth tokens scope differently).
- Drift becomes obvious within first week of dual maintenance.

**Cross-refs:**
- TD-24 / TD-27 — drift management lesson informs the parity-test design.
- TD-25 — multi-account loop pattern is one of the patterns the bake-off must validate translates cleanly.

**Maintainer skill addendum (already shipped in v0.23.0):** `foundry-skillpack-builder` SKILL.md invariant #9 already requires verify-on-touch for api-versions; that discipline transfers directly to dual-script maintenance.

**Out of scope until decision lands:**
- Don't write `.ps1` siblings for scripts other than the bake-off candidate.
- Don't update install-prereqs.sh to provision pwsh (gated on dual-script direction being approved).
- Don't ship pwsh into `.agents/skills/` via `apm install` (no consumer impact until dual is decided).

## TD-29 — AGT (Microsoft Agent Governance Toolkit) as a declarable runtime-governance layer (OPEN — v0.24 firm)

> **Design doc (DRAFT, for review):** [`../../design/td-29-agt-integration.md`](../../design/td-29-agt-integration.md). Proposes a 3-tier integration model (core / opt-in add-ons / explicitly-not-integrated) grounded in a 2026-05-26 AGT spike. Reviewers: answer the questions in §10 before Phase 3 implementation starts.

**What:** [Microsoft Agent Governance Toolkit](https://github.com/microsoft/agent-governance-toolkit) (AGT) is the runtime governance layer for AI agents — official `microsoft/` org, v3.7.0, 2.3k stars, 102 contributors, multi-language SDK (Python full / TypeScript / .NET / Rust / Go), OpenSSF Scorecard, RFC 2119 specs with 992 conformance tests, OWASP Agentic Top 10 / NIST AI RMF / EU AI Act / SOC 2 mappings. AGT explicitly lists Azure AI Foundry as one of its supported deployment targets. **This skillpack does not currently integrate with AGT and does not reference it.**

**Why this is debt:** A consumer who discovers AGT independently and then finds this skillpack will reasonably ask "are these competing?" without explicit positioning. They are not — AGT is runtime middleware (per-tool-call policy + identity + audit) and we are deploy + lifecycle orchestration (provision + RBAC + capability gates + Foundry-native evals + Teams publish). They sit on different layers of the same stack. But without explicit integration the consumer has to wire AGT into their Foundry agent manually, outside our orchestration, which fragments configuration and breaks the audit story (AGT's Merkle log lives separately from our `/audit-drift` reconciliation).

**Strategic posture: adopt and integrate, not compete.** AGT is larger, well-funded, and structurally correct for its layer. Our value is everything outside the container that AGT cannot do.

**Close-out (intended shape, v0.24 firm):**

1. **`agent-capabilities.yaml` accepts a new top-level key:**

   ```yaml
   runtime_governance:
     provider: agt                        # or 'none' (default)
     policy_file: governance/policy.yaml  # AGT YAML / OPA / Cedar
     fail_mode: deny                      # deny | allow | require_approval
     audit_sink: merkle                   # merkle | otel | both
   ```

2. **`/prepare-deploy` gate**, when `runtime_governance.provider == agt`:
   - Injects `agent-governance-toolkit[full]` into the agent's container `requirements.txt`.
   - Validates the referenced policy file with `agt lint-policy`.
   - Emits the AGT-required env vars (`AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_CLIENT_SECRET` for Azure-integrated AGT features) into the deployment manifest.

3. **Skillpack agent templates** (`agent-framework` and `langgraph-byo` under `foundry-deploy/templates/`) include a commented-out `govern(...)` wrap example next to each declared tool function. Uncommented automatically when AGT is the declared provider.

4. **Foundry-native eval rules cross-link AGT decisions** through OTel spans (AGT decision records become `evaluator.agt.*` span attributes), so App Insights includes per-tool-call policy outcomes alongside eval rule results in a single timeline.

5. **`foundry-guardrails` skill** gains an "AGT integration" section under a new Layer 0 (deterministic runtime enforcement, ordered before middleware). Current four-layer model becomes a five-layer model with AGT optional but recommended.

6. **`/audit-drift`** reconciles declared `runtime_governance.policy_file` against the policy file present in the deployed container image (catches the drift case where policy is edited locally but not redeployed).

7. **OWASP Agentic Top 10 mapping table** in `docs/concepts/related-work.md` becomes the formal compliance bridge — each row maps the risk to AGT's mitigation (runtime) and our mitigation (provisioning). Promotes "we cover OWASP through both layers" to a defensible claim instead of marketing copy.

**Why deferred from v0.23.0:**
- The `agent-capabilities.yaml` schema bump is breaking-shaped for downstream consumers; needs design review against TD-19 alias-window discipline.
- AGT itself is at v3.7.0 ("Public Preview") with breaking-change risk before GA — want to land integration against a stable AGT minor.
- Template injection of `govern(...)` boilerplate needs a real bake-off (does it work cleanly with our existing agent-framework + langgraph-byo templates? what does the `tool_name` convention look like across both?).
- Needs alignment with TD-30 (compliance mapping) since both touch the same OWASP table.

**Decision criteria for "AGT integration ships in v0.24":**
- AGT releases v4.0 / GA (or a sufficiently stable v3.x for our integration window).
- We confirm AGT's `govern(...)` SDK works inside the Foundry hosted-agent container (no conflicts with the agent-framework or langgraph runtime).
- Policy file format is validated against at least 3 real Foundry use-cases (knowledge-source-only agent, Fabric+Teams agent, multi-agent orchestration).

**Sequencing:** TD-29 is firmed to v0.24 as the headline. TD-28 (cross-OS bake-off) runs as research in parallel during v0.24 but does not ship consumer-visible pwsh scripts until v0.25. Different code paths, different reviewer brains; bundling risks delivering neither well.

**Cross-refs:**
- TD-30 (compliance mapping) — will follow once AGT integration lands so the mapping is grounded in actual mechanisms, not theoretical coverage.
- `foundry-guardrails` skill SKILL.md — will need Layer 0 section added.
- `docs/concepts/related-work.md` — the consumer-facing version of this story; updated in v0.23.0 alongside this TD entry.

**Out of scope:**
- Replacing our `foundry-guardrails` Layer 1-4 with AGT. AGT does not cover Purview DLP (Layer 1.5 unique enforcement gap), Foundry-native Content Safety, or Foundry-native eval/red-team — these stay as ours and are complementary to AGT's runtime policy engine.
- Adopting AGT's SPIFFE/DID identity primitive for Foundry agents. Foundry agents already have Entra Agent ID + project/agent/application identity flip — the Microsoft-native model. AGT's identity model is for cross-cloud / multi-runtime scenarios where Entra is not the issuer.


## TD-30 — Foundry RBAC role rename + `Azure AI Developer` misuse (CLOSED in v0.24.0)

**Status (v0.24.0):** Closed. Two parallel issues fixed in one pass after a Microsoft Learn re-verification on 2026-06-08.

**Issue 1 — Rename.** Microsoft renamed four built-in Foundry data-plane roles (role IDs and permissions unchanged):

| Old name | New name | Role definition ID |
|---|---|---|
| Azure AI User | **Foundry User** | `53ca6127-db72-4b80-b1b0-d745d6d5456d` |
| Azure AI Owner | **Foundry Owner** | `c883944f-8b7b-4483-af10-35834be79c4a` |
| Azure AI Account Owner | **Foundry Account Owner** | `e47c6f54-e4a2-4754-9501-8e0985b135e1` |
| Azure AI Project Manager | **Foundry Project Manager** | `eadc314b-1a2d-4efa-be10-5d325db5065e` |

Microsoft Learn ([rbac-foundry](https://learn.microsoft.com/azure/foundry/concepts/rbac-foundry#built-in-roles), [quickstart](https://learn.microsoft.com/azure/foundry/tutorials/quickstart-create-foundry-resources#for-administrators---grant-access)) notes: *"You might still see the previous names in some places while the rename rolls out. … use the role definition ID (GUID) instead of the role name in your code to avoid issues during the rename rollout."*

**Issue 2 — `Azure AI Developer` is wrong for hosted agents.** [Hosted agent permissions reference](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agent-permissions) is explicit: *"Although it might sound like an appropriate role for a developer working with Hosted agents, the **Azure AI Developer** built-in role is insufficient for Hosted agent scenarios. This role is scoped to Azure Machine Learning and Foundry hubs, not to the Foundry project resources used by Hosted agents."* We were using `Azure AI Developer` as the `prepare-deploy` minimum on the project (wrong) and as a per-agent SP grant (wrong — `Foundry User` is the only documented per-agent runtime role).

**Close-out (what shipped in v0.24.0):**

1. **Prose** — every `.apm/` doc and prompt that named one of the four roles now uses the new `Foundry *` name, with a one-line rollout note explaining the rename + per-row role-ID column added to [foundry-roles/role-matrix.md](.apm/skills/foundry-roles/role-matrix.md).
2. **Scripts that grant** ([foundry-identity/scripts/grant-rbac.sh](.apm/skills/foundry-identity/scripts/grant-rbac.sh)) — switched from role name to role **GUID** in every `az role assignment create` per Microsoft Learn's explicit guidance.
3. **Scripts that preflight** ([foundry-roles/scripts/preflight-role.sh](.apm/skills/foundry-roles/scripts/preflight-role.sh)) — now alias-aware: accepts either the old or new role name as input, and matches against either name (or the role-definition ID) returned by `az role assignment list`. Required because tenants in the middle of the rollout return one or the other depending on backend caching.
4. **`Azure AI Developer` removed** from `/prepare-deploy` minimums, from the `publish-teams` preflight, from the per-agent grant fan-out, and from the role-matrix Phase 2 table. Replaced with `Foundry Project Manager` (for `prepare-deploy` and `publish-teams`, which need project-config writes on the version) and dropped entirely from the per-agent SP grants (the hosted-agent permissions doc says `Foundry User` is the only role the per-agent SP needs at runtime).
5. **Playbook recipes 01, 03, 04, 06** updated to the new names (auto-mirrored to the docs site via [`docs/scripts/mirror-recipes.mjs`](../docs/scripts/mirror-recipes.mjs)).
6. **Docs site** hand-curated pages updated: `docs/src/content/docs/reference/role-matrix.md`, `reference/prompts.md`, `concepts/personas-and-roles.md`.

**Verification:** After install,
```bash
grep -RIn --include='*.md' --include='*.sh' --include='*.py' \
  -E 'Azure AI (User|Owner|Account Owner|Project Manager|Developer)\b' \
  foundry-agent-skillpack/.apm foundry-agent-playbook/.apm
```
should return only the TD-30 entry itself + the `role-matrix.md` rename-note table (the deliberate "previously named …" callout). Anything else is a regression.

**Why the GUID switch is non-optional for the grant path:** When Microsoft drops the old name aliases (planned but no date given), any consumer that pinned an old install with a script doing `az role assignment create --role "Azure AI User" …` will start getting `RoleDefinitionDoesNotExist`. Switching to the GUID future-proofs every grant the skillpack makes.

---

## TD-31 — Source-code (zip) deploy preview path was missing entirely

**Status:** CLOSED in v0.25.0

**Issue:** The skillpack was authored against the original hosted-agents preview, which was **container-only**. Microsoft has since added a parallel **source-code (zip) deploy** path (`POST /agents` with `code_configuration`, multipart `code=@agent.zip`, `Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview`, `api-version=2025-11-15-preview`) — see [Deploy a hosted agent from source code (preview)](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent-code). Customers on `azd ai agent init --deploy-mode code` had no first-class support; the skillpack would silently route them down the container preflight, fail on missing Dockerfile, or worse, scaffold a Dockerfile they didn't want. Folds in six related must-fix gaps (G-1 through G-6) so the path works end-to-end.

**Close-out** (v0.25.0):

1. **G-1 — first-class code-deploy reference (`code-deploy.md`).** New skill doc `foundry-agent-skillpack/.apm/skills/foundry-deploy/code-deploy.md` covers: when to pick code vs container, manifest `deploy_mode` / `code:` block, SDK Python `project.beta.agents.create_version_from_code` + `download_code` (requires `azure-ai-projects>=2.2.0` + `allow_preview=True`), SDK .NET `CreateAgentVersionFromCode` + `FeaturePolicy`, REST multipart shape with `x-ms-agent-name` + `x-ms-code-zip-sha256`, `azd ai agent init --deploy-mode code`, packaging (flat zip layout, `remote_build` default vs `bundled` with `pip install --target packages/ --platform manylinux2014_x86_64 --python-version 3.13 --implementation cp --only-binary=:all:`), content-addressable versioning, `code:download`, `:logstream`, `&force=true` cascade-delete, 250MB limit, RBAC (Foundry Project Manager + platform-MI Foundry User), troubleshooting table cross-linking F-21–F-28. Router (`foundry-deploy/SKILL.md`) wires the new doc in + critical reminder about deploy_mode + content-addressable versioning. `scaffold.md` opens with a callout pointing code-deploy users here.

2. **G-2 — preview-features header.** `rest-api.md` now documents BOTH `Foundry-Features` header values:
   - Container path mutating calls → `Foundry-Features: HostedAgents=V1Preview` (unchanged)
   - Code-deploy path mutating calls → `Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview`
   - GET / list / version-detail calls require neither.
   - `:logstream` requires neither.

3. **G-3 — api-version `2025-11-15-preview` for code-deploy.** Container path stays on `api-version=v1`. `rest-api.md` and `version-lifecycle.md` both document the split. `code-deploy.md` uses the preview api-version throughout.

4. **G-4 — content-addressable versioning + drift detection.** `version-lifecycle.md` adds a dedicated section explaining: the service mints a new version **only when the zip's SHA-256 OR the agent definition actually changes**; identical reposts return the existing latest; `versions.latest` does NOT advance. `/audit-drift` MUST compare local zip SHA-256 to `x-ms-code-zip-sha256` on `GET .../code:download` (and local `metadata.json` to server `versions.latest.code_configuration`). `agent-status-schema.md` bumped to **v1.3** (additive — no `schema_version` bump): `deploy.deploy_mode` (`container` | `code`), and for code-deploy `deploy.zip_sha256`, `deploy.runtime`, `deploy.dependency_resolution`. Changelog entry added.

5. **G-5 — eight new failure modes (F-21 through F-28).** `foundry-failure-modes/SKILL.md` description bumped from "25 verified" → "32 verified (incl. code-deploy preview)". New "Source-code Deploy (preview) Failures" section covers:
   - **F-21** `400 CPU and Memory must be a valid resource tier`
   - **F-22** `400 Agent version is still being provisioned` on invoke during version swap
   - **F-23** `424 session_not_ready` → `x-agent-session-id` + `:logstream`
   - **F-24** `409 Agent has active sessions` on DELETE → `&force=true` cascade
   - **F-25** Version stuck in `creating` >10 min → switch `remote_build` → `bundled`
   - **F-26** `ModuleNotFoundError` at runtime → rebuild with `--platform manylinux2014_x86_64 --only-binary=:all:`, verify `packages/` is **extracted modules** not raw `.whl`
   - **F-27** `409 AgentNotCodeBased` on `code:download` (agent is image-based)
   - **F-28** `401 Unauthorized` on agent CRUD → token audience must be `https://ai.azure.com`
   Quick Triage table also extended with 4 fast-path lookups for the most common ones.

6. **G-6 — SDK floor + `allow_preview=True`.** `runtime-dependencies.md` caller-side block calls out the conditional bump: default floor stays `azure-ai-projects>=2.0.0,<3` (most callers only do reads); machines that invoke `project.beta.agents.create_version_from_code` / `download_code` directly must bump to `>=2.2.0,<3`. `sdk-surface.md` adds a "Code-deploy SDK surface (preview)" section pointing to `code-deploy.md` for the full pattern with `allow_preview=True` and the note that `project.agents.*` (no `beta`) remains the correct surface for reads.

**Schema + prompt updates** (the glue that makes the above usable):

- **`capabilities-manifest.md`** schema extended with `deploy_mode: container|code` (default `container`, back-compat) + `code:` block (`runtime`, `entry_point`, `dependency_resolution`, `protocol`). Validation rules: `deploy_mode: code` requires the full `code:` block; INCOMPATIBLE with a sibling `Dockerfile`; `runtime` ∈ {`python_3_13`, `python_3_14`, `dotnet_10`}; `bundled` requires the local build step to have been run before `/prepare-deploy`. New Gate Matrix row (`deploy_mode: code`) covers Phase A (manifest + zip layout + extension version + caller role), Phase B (none — platform-MI auto), Phase C (SHA echo match, first invoke not 424, no `CodeError`).
- **`/prepare-deploy` Step 1** now forks on `deploy_mode` (in addition to `agent_kind`). New **Track H-Code** (H6-H11) replaces the container H1-H5 when `deploy_mode: code`: manifest `code:` block validation, flat-zip layout check (`unzip -l` MUST NOT show single common prefix folder), dependency-strategy check (`packages/` extracted not `.whl` for Python; `dotnet publish` shape for .NET), runtime match, azd extension `--deploy-mode code` support, caller-side SDK floor note.
- **`/plan-agent` Track B** asks the deploy_mode question once, then forks into Step 3 (container, default) or **Step 3-Code** (no Dockerfile, no ACR; writes `deploy_mode: code` + `code:` block to manifest; optional `azd ai agent init --deploy-mode code` scaffolder).

**Cross-ref to TD-30:** The deploy-from-code MS Learn doc independently confirms TD-30's role minimums:
- Caller deploying a code-based hosted agent needs **`Foundry Project Manager`** at project scope (NOT `Azure AI Developer`).
- The agent's platform-assigned managed identity needs **`Foundry User`** at project scope to call models. Platform assigns this MI automatically.

**Verification:** After install,
```bash
# 1. Drift between source-of-truth and installed copies
node docs/scripts/check-drift.mjs            # expect "no drift detected"

# 2. apm install smoke
apm install foundry-agent-skillpack --target copilot
# expect 15 skills + 9 prompts + 1 agent

# 3. Confirm both feature-flag values are documented
grep -RIn 'Foundry-Features: CodeAgents=V1Preview' foundry-agent-skillpack/.apm/skills/foundry-deploy
# expect hits in code-deploy.md (multiple) + rest-api.md (1)

# 4. Confirm the schema bump landed
grep -n 'deploy_mode' foundry-agent-skillpack/.apm/skills/foundry-deploy/capabilities-manifest.md \
                     foundry-agent-skillpack/.apm/skills/foundry-deploy/agent-status-schema.md \
                     foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md \
                     foundry-agent-skillpack/.apm/prompts/plan-agent.prompt.md
# expect hits in all four

# 5. Confirm new failure modes exist
grep -nE '^- \*\*F-2[1-8]' foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md
# expect 8 lines (F-21 through F-28)
```

**Why folding G-1 through G-6 into one TD instead of six:** G-2 (header), G-3 (api-version), G-6 (SDK floor + `allow_preview`) are mechanical prerequisites for G-1 (the doc) to actually be runnable end-to-end. G-4 (content-addressable versioning) and G-5 (new failure modes) only manifest on the code-deploy path, so they have to land in the same release or `/audit-drift` will misreport "no version change" as a regression. Shipping any of these without the others would leave a half-functional preview surface.



## TD-32 — Pre-development Foundry project topology discovery was missing entirely (CLOSED in v0.26.0)

**What:** The skillpack had no read-only audit surface. `discover-target.sh` answered the deploy-time minimum-set question (account + project + ACR + 1 model deployment); nothing answered the **assessment-time** question — "what is the *full* shape of this Foundry project, and which parts will block, weaken, or simply fail to surface a working agent?" Six recurring scenarios surfaced this gap: portal-provisioned silent gap, missing knowledge connection, joining a 6-month-old project, continuous-eval traces missing, pre-deploy CI gate, pre-sales briefing.

**Status (v0.26.0):** Closed. Ships as a **general skillpack capability** (not just a TD-row internal feature) with explicit docs-site presence under Concepts → [Project assessment](docs/src/content/docs/concepts/project-assessment.md). Six artifacts:

1. **New reference doc:** [`foundry-deploy/project-topology.md`](.apm/skills/foundry-deploy/project-topology.md) — opens with the Foundry Toolkit boundary matrix (Toolkit owns interactive browse / wire / deploy; this skillpack owns verdict + stub + lifecycle integration + CI gate). Lists every resource category, the api-version each is pinned to (`accounts/projects`, `accounts/projects/connections`, `accounts/projects/capabilityHosts`, `accounts/networkInjections` all on `2026-03-01` GA; `accounts/projects/agents` on `v1` via `https://ai.azure.com` audience per F-28), what missing triggers (verdict ✅/⚠/❌), cross-skill ownership map, exit codes (0 / 2 / 3), CI gate pattern.
2. **New shell script:** [`foundry-deploy/scripts/discover-project-topology.sh`](.apm/skills/foundry-deploy/scripts/discover-project-topology.sh) — single ARM walk emitting KEY=VALUE to stdout, human context to stderr. Eight grouped prefixes: `ACCOUNT_*`, `PROJECT_*`, `CONNECTION_*`, `CAPHOST_*`, `NETWORK_*`, `DEPLOYMENT_*`, `AGENT_*`, `IDENTITY_*`. Foundry-grade gate on `allowProjectManagement`. `set -euo pipefail`. Stderr captured on every `az rest` call per invariant #9. Exit `0` ok / `2` not-foundry-grade / `3` no-account.
3. **New python formatter:** [`foundry-deploy/scripts/discover-project-topology.py`](.apm/skills/foundry-deploy/scripts/discover-project-topology.py) — consumes the KEY=VALUE stream, emits three artifacts: `project-topology.md` (verdict per category + Top 3 + per-category detail), `project-topology.json` (CI-readable), `agent-capabilities.draft.yaml` (pre-filled stub with `# TODO` markers — non-mutating, manual `mv` to promote).
4. **New prompt:** [`/assess-project`](.apm/prompts/assess-project.prompt.md) — read-only audit. Steps 0=caller role preflight, 1=shell discovery, 2=python formatter, 3=render md inline + summary, 4=offer handoff to `/plan-agent`. Forbidden shortcuts: no mutations, no fix execution, no model deploy.
5. **New docs concept page:** [Project assessment](docs/src/content/docs/concepts/project-assessment.md) — surfaces the capability as a general skillpack feature per user direction. Documents all six scenarios verbatim, Foundry Toolkit boundary matrix, verdict rubric, "where this does NOT help" non-goals, lifecycle plug-in points. Added to `astro.config.mjs` sidebar under Concepts.
6. **Lifecycle integrations:** `foundry-deploy/SKILL.md` router row; `/plan-agent` Step 0a new Step 0 (cached topology fast path — skips re-prompting when `./assessment/` exists); `/prepare-deploy` Step 2.5 new cross-check block (warns on three mismatch patterns, stamps `preflight.topology_crosscheck` additive); `/troubleshoot` Step 3 new Scenario 4 hook (re-checks topology when symptom matches a topology gap pattern). All additive — no schema_version bump.

**Verification:**

```bash
# 1. Drift check
node docs/scripts/check-drift.mjs                                              # expect "no drift detected"

# 2. Script syntax
bash -n foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-project-topology.sh
python3 -m py_compile foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-project-topology.py

# 3. APM install smoke (expect 15 skills + 10 prompts + 1 agent — prompt +1 from v0.25.0)
apm install ./foundry-agent-skillpack --target copilot --force

# 4. Confirm router row + reference doc landed
grep -n 'discover-project-topology\|project-topology.md' foundry-agent-skillpack/.apm/skills/foundry-deploy/SKILL.md

# 5. Confirm integration hooks landed
grep -n 'project-topology\.json\|project-topology\.md\|assess-project\|/assessment/' \
  foundry-agent-skillpack/.apm/prompts/plan-agent.prompt.md \
  foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md \
  foundry-agent-skillpack/.apm/prompts/troubleshoot.prompt.md
# expect hits in all three
```

**Cross-ref to TD-31:** TD-31 introduced the code-deploy path; TD-32 introduces the assessment path that *answers* "is this project ready for either a container OR a code deploy?" The two close together because both surface at the same lifecycle moment (between project provisioning and `/plan-agent`).

**Cross-ref to Foundry Toolkit:** The boundary is explicit in both `project-topology.md` and the docs concept page. We do NOT browse the model catalog, deploy from a card click, or render a Toolboxes UI — Toolkit owns those. We own the verdict, the stub, the cached output that `/plan-agent` / `/prepare-deploy` / `/troubleshoot` reuse, and the CI gate shape.

**Post-write defect fix (real-world test caught it before any external ship):**

Tested against RG `agents-3iq` which has **3 Foundry-grade accounts** (`foundry-res-eastus`, `agents-3iq-eastus2`, `agents-3iq-ncus-2`) plus 1 ContentSafety. The first pass silently picked `foundry-res-eastus` (index 0) and emitted ✅ on Model deployments because there are 20 deployments *in the RG*. The user immediately flagged it: *"what why is there no ask on project name and how is the assessment done across multiple resources/projects in same RG — isn't it going to lose context and lose track here?"* They were 100% right. Per-account walk confirmed dramatic shape variance:

| Account | Connections | CapHosts | Own deployments | Agents |
|---|---|---|---|---|
| `foundry-res-eastus` (the silent default) | 3 | 0 | **0** | **0** |
| `agents-3iq-eastus2` | 9 | 0 | **16** | **3** |
| `agents-3iq-ncus-2` | 14 | **1** | 4 | 0 |

The silent path would have audited the *emptiest* account while the real workload lives on the other two. Four surgical fixes shipped under the same v0.26.0:

1. **Shell ambiguity gate (exit code 4).** When `$3=HINT_ACCOUNT` is empty AND multiple Foundry-grade accounts exist, the script refuses to pick. It eagerly emits ALL candidates (`ACCOUNT_NAME_<n>=` / `ACCOUNT_KIND_<n>=` / `ACCOUNT_FOUNDRY_GRADE_COUNT=`) to stdout BEFORE exiting 4, so the calling prompt can render a structured picklist programmatically. Same pattern for projects (`PROJECT_NAME_<n>=` before exit 4). **CI must always pass both positionals**; auto-pick is an interactive convenience for `/assess-project`, never a CI default.
2. **Python deployment verdict.** Rewrote `verdict_deployments` to split own-account vs cross-account counts using new shell signals `DEPLOYMENT_OWN_ACCOUNT_COUNT` / `DEPLOYMENT_OWN_ACCOUNT_NAME`. Old behaviour aggregated all RG deployments and showed ✅ even when the chosen project's account had zero — actively misleading because cross-account references mean extra latency + cross-account RBAC. Now emits ⚠ "Zero deployments on chosen project's account (`<name>`); `<n>` on sibling account(s)" when own=0 AND cross>0; emits ✅ with `(+<n> cross-account in this RG)` suffix when both are present.
3. **`/assess-project` Step 1 picklist dispatch.** On exit 4, parse `/tmp/topology.kv`, grep `ACCOUNT_NAME_<n>=` siblings, present Foundry-grade-only numbered picklist (non-Foundry shown unpickable for context), wait for user selection, re-invoke the script with chosen account as positional arg 3. Same dispatch for `PROJECT_NAME_<n>=` with arg 4. Frontmatter docs updated: `account_name` / `project_name` are now "REQUIRED only when ambiguous (script exits 4 with picklist; this prompt re-invokes with the user's choice)".
4. **`foundry-deploy/project-topology.md` exit-codes table.** New row for code 4 describing the ambiguous-state behaviour and the candidate-emission-before-gate contract; explicit CI warning that auto-pick is interactive-only.

**Lesson learned:** Silent auto-pick on ambiguous topology = wrong-project audit. Always emit candidates eagerly to stdout BEFORE the gate so picklists work programmatically *and* the human signal lives on stderr where it belongs. This now becomes a convention any future "single-shape" discovery script in this skillpack must follow.


## TD-33 — `/assess-project` was three sequential tool round-trips (CLOSED in v0.26.0)

**Discovered:** Real-world test of TD-32 against `agents-3iq` exposed UX friction. `/assess-project` invoked `preflight-roles.sh`, then `discover-project-topology.sh`, then `discover-project-topology.py` as three separate `run_in_terminal` calls. Each is a turn-of-latency + a separate place to fail silently. The happy path "look at a project" required three round-trips before the user saw anything.

**Root cause:** The prompt was authored as a strictly-composable chain — each script standalone-usable, each invocation visible to the agent. Composability is correct for CI / direct script use, but for an interactive prompt it leaks plumbing into the user-visible tool log.

**Fix shipped under v0.26.0 (folded into the same release as TD-32 since it's the same surface):**

1. **New wrapper:** `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/assess-project.sh`. Single bash entry that runs preflight (best-effort, non-blocking — `assess-project` alias may not exist on older installs of `preflight-roles.sh`), discovery, and formatting in one go. Propagates exit codes (especially exit 4 for ambiguous-account/project picklist dispatch). Emits machine-readable pointers on stdout: `ASSESSMENT_STATUS={ok|ambiguous}`, `ASSESSMENT_REPORT_MD=...`, `ASSESSMENT_REPORT_JSON=...`, `ASSESSMENT_STUB_YAML=...`, `ASSESSMENT_KV_FILE=...`. Stderr tails on failure (invariant #9).
2. **`/assess-project` prompt slim:** collapsed Steps 0+1+2 (separate preflight + discover + format invocations) into a single Step 1 "run wrapper". Step 2 is now reserved for the exit-4 picklist dispatch only. Step 3 is the verdict render, Step 4 the stub handoff, Step 5 (NEW) the capability-host remediation offer (cross-link to `/add-capability-host`).
3. **Preflight alias:** added `assess-project` case branch in `preflight-roles.sh` so the wrapper's preflight no longer falls through to "unknown alias" on fresh installs. Documents Reader-on-RG as the required role; non-blocking.
4. **Forbidden-shortcuts addition:** the prompt now explicitly forbids calling `discover-project-topology.sh` and the Python formatter separately when the wrapper exists — that pattern wastes a round-trip and bypasses the wrapper's stderr-tail safety.

**Net effect:** happy path is 1 tool call (was 3). Ambiguous-account path is 2 (was 3). All exit-code semantics + picklist eager-emit behaviour preserved.

**Verification:**
```bash
# Same RG that exposed the issue
.agents/skills/foundry-deploy/scripts/assess-project.sh \
  d194e976-63c4-43c9-995a-5340d0daffb1 agents-3iq
# expect: exit 4, ACCOUNT_NAME_<n>= candidate list on stdout, picklist on stderr

# Disambiguated re-invocation
.agents/skills/foundry-deploy/scripts/assess-project.sh \
  d194e976-63c4-43c9-995a-5340d0daffb1 agents-3iq agents-3iq-eastus2
# expect: exit 0, ASSESSMENT_REPORT_MD=./assessment/project-topology.md
```

**Cross-ref to TD-32:** TD-32 was the topology-discovery surface; TD-33 is its UX wrapper. They close together because the wrapper would not exist without the underlying script.


## TD-34 — `/add-capability-host` real remediation for ⚠ verdicts (CLOSED in v0.26.0)

**Discovered:** Real-world test of TD-32 also exposed that the `Capability hosts` ⚠ verdict pointed only to a doc reference (`capabilities-manifest.md`) with no actionable remediation path. The first reflex was to *soften the verdict to informational* on the grounds that "capability hosts are a preview surface". This was wrong — capabilityHosts are GA at `api-version=2026-03-01` with full BYO support, and `ENABLE_CAPABILITY_HOST=false` in `instructions/foundry-conventions.md` is the **azd-extension scaffold default only** (azd doesn't provision the prerequisite Cosmos / AI Search / Storage resources). The platform fully supports the BYO path at runtime.

**Root cause:** Verdict-softening as a "fix" is a sloppy/lazy shortcut. The user pushed back: *"I see that you often tend to take sloppy lazy route in fixing the problems."* That feedback drove a real remediation: build the missing `/add-capability-host` prompt + mutator + reference doc end-to-end, plus fix two hidden defects exposed during research.

**Defects exposed during research:**

1. `discover-project-topology.sh` only probed **project-level** capabilityHosts (`accounts/{}/projects/{}/capabilityHosts`). It missed **account-level** capabilityHosts entirely. Tested against `agents-3iq-eastus2` which has a bare `default` account-level host — the script reported `Hosts=0` and the verdict was indistinguishable from "no caphost at any scope" (which is a different remediation path).
2. The verdict text said "memory/thread/vector stores" but `memoryStoreConnections` was deprecated in the `2026-03-01` schema. The shape is now `threadStorageConnections` + `vectorStoreConnections` + `storageConnections` + optional `aiServicesConnections`.

**Fix shipped under v0.26.0:**

1. **Hidden defect — account-level capHost probe.** Modified `discover-project-topology.sh` § 4 to probe BOTH scopes. New signals:
   - `CAPHOST_ACCOUNT_COUNT`, `CAPHOST_ACCOUNT_<n>_{NAME,KIND,PROV_STATE,THREAD_CONN_COUNT,VECTOR_CONN_COUNT,STORAGE_CONN_COUNT}`
   - `CAPHOST_PROJECT_COUNT`, `CAPHOST_PROJECT_<n>_{NAME,KIND,PROV_STATE,THREAD_CONNECTIONS,VECTOR_CONNECTIONS,STORAGE_CONNECTIONS,AISERVICES_CONNECTIONS}` (CSV of connection names so the formatter can cross-check `metadata.ResourceId` on each)
   - Legacy `CAPHOST_COUNT` kept as alias for `CAPHOST_PROJECT_COUNT` (backwards compat with TD-32-initial formatter).

2. **`verdict_capability_hosts` rewrite (Python formatter).** Four-case verdict with specific remediation pointer to `/add-capability-host`:
   - **neither** → ⚠ "No capability hosts (account or project scope)" + "Run `/add-capability-host`"
   - **account only** → ⚠ "Account capHost '\<name\>' exists, project capHost missing" + "Run `/add-capability-host --scope project`"
   - **project only** → ⚠ "Anomalous: project capHost present but no account-level capHost" (shouldn't normally happen)
   - **both with full BYO** → ✅ "Project capHost '\<name\>' fully wired (thread + vector + storage)"
   - **both with partial bindings** → ⚠ "BYO bindings partial. Missing: \<list\>. Use `/add-capability-host --force-recreate`"

3. **Hidden defect — `metadata.ResourceId` per connection.** Modified `discover-project-topology.sh` § 3 to emit `CONNECTION_<n>_RESOURCE_ID=` for every connection. Per the Foundry capability-hosts doc, the runtime requires `metadata.ResourceId` to be populated on every connection a capabilityHost references — without it, the PUT succeeds but the runtime silently falls back to default storage. `/add-capability-host` now blocks at preflight if any chosen connection has empty `ResourceId`.

4. **New reference doc:** `foundry-agent-skillpack/.apm/skills/foundry-deploy/capability-host-bootstrap.md`. Sections: why this exists (mode 1 default-managed vs mode 2 BYO), the REST shape at both scopes, naming convention (`account-capability-host` / `project-capability-host`), two-scope ordering rule (account first, 409 otherwise), required connections + `metadata.ResourceId` rule, idempotency contract (no UPDATE — only DELETE + CREATE), RBAC matrix, verification GETs, common failure modes table.

5. **New mutator script:** `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/add-capability-host.sh`. Dry-run by default; live mutation requires explicit `--no-dry-run`. Supports `--scope account|project|both`, `--{thread,vector,storage,aiservices}-conn <name>`, `--auto-pick` (auto-resolve when exactly one connection per category), `--force-recreate` (DELETE + CREATE for partial-bindings cases). Polls `provisioningState` until `Succeeded` (3min timeout). Exit codes: 0 ok / 2 ambiguous-connection (picklist on stdout) / 3 empty-`ResourceId` / 4 already-exists-no-force / 5 dry-run-complete.

6. **New prompt:** `foundry-agent-skillpack/.apm/prompts/add-capability-host.prompt.md`. Seven steps: preflight → cached topology pickup (from `/assess-project`'s JSON) → connection selection (picklist if ambiguous) → dry-run (always first) → render PUT bodies to user → explicit `yes` consent (additional `yes confirm delete` if DELETE is in the plan) → apply with `--no-dry-run` → re-run `/assess-project` to verify ⚠ → ✅. Forbidden shortcuts: never skip dry-run, never silently auto-pick, never pass `--force-recreate` without explicit consent.

7. **Preflight alias:** added `add-capability-host` case branch in `preflight-roles.sh`. Requires Contributor on the Foundry account (capabilityHosts subresource is gated by account-level Contributor, same as connections — `Cognitive Services Contributor` is NOT sufficient, verified during TD-32).

8. **Conventions clarification:** updated `instructions/foundry-conventions.md` § Bicep to explicitly scope `ENABLE_CAPABILITY_HOST=false` to the azd-extension scaffold default only — with a cross-link to `capability-host-bootstrap.md` for the runtime BYO path. Same clarification in `prompts/prepare-deploy.prompt.md` env-var checklist.

9. **`/assess-project` Step 5 (NEW):** offer to hand off to `/add-capability-host` whenever the Capability hosts row is ⚠. Reads `project-topology.json` to pre-resolve all parameters; only proceeds with explicit user consent.

**Bring-your-own (BYO) inline connection create — option (b) extension (same release):** the initial mutator handled only the "pick an existing project connection" path, which would `exit 1` whenever a category had zero connections (forcing the user out to the Foundry portal). User pushback during live test against the empty `foundry-res-eastus` project: *"capability host concept is to bring your own cosmos storage & search right…"* — confirmed against MS Learn (standard-agent-setup; ARM caphosts ref). The script now accepts `--thread-resource-id` / `--vector-resource-id` / `--storage-resource-id` (one ARM ID each) and creates the matching Foundry connection inline before the capHost PUT. Connection bodies were captured live from a working `agents-3iq-ncus-2/proj-agents-ncus-2` project to lock the exact shape:

- Cosmos: `category: "CosmosDb"`, target `https://<name>.documents.azure.com:443/`, 3 metadata keys (`ApiType`, `ResourceId`, `location`).
- AI Search: `category: "CognitiveSearch"`, target `https://<name>.search.windows.net`, 4 metadata keys (`ApiType`, `ApiVersion: "2024-05-01-preview"`, `DeploymentApiVersion: "2023-11-01"`, `ResourceId`, `location`).
- Storage: `category: "AzureStorageAccount"`, target `https://<name>.blob.core.windows.net`, 2 metadata keys (`ApiType`, `ResourceId`) — no `location`.
- All `authType: "AAD"`, `isSharedToAll: true`. `metadata.ResourceId` is the BYO ARM ID itself.

`resolve_binding()` priority per role: (1) `--<role>-conn <name>` matches existing → use, (2) `--<role>-resource-id <arm-id>` → plan inline create, (3) auto-pick if exactly one candidate, (4) multiple candidates no `--<role>-conn` → exit 2, (5) zero candidates no `--<role>-resource-id` → exit 1. ARM provider-segment validation per role (e.g. `--vector-resource-id` must point to `Microsoft.Search/searchServices`). New Step 7a in the script: in `--no-dry-run` mode PUTs each queued connection then re-GETs to confirm `metadata.ResourceId` populated; aborts before capHost PUT on verification failure. Dry-run prints `project connections to CREATE: N` summary and per-connection PUT bodies before the capHost bodies; emits `CONNECTIONS_TO_CREATE_COUNT=` + per-connection `CONNECTION_TO_CREATE_<n>_{NAME,CATEGORY}=` machine-readable lines.

**Latent bug fixed under same release:** wrong category constant `AzureCosmosDb` in the resolution loop (real Foundry API uses `CosmosDb` — confirmed by GET against live project). Would have made `--auto-pick` always fail to find thread connections.

**Prompt + reference doc updated:** `/add-capability-host` prompt grew `thread_resource_id` / `vector_resource_id` / `storage_resource_id` inputs and a Step 2 sub-branch that offers users two options when a category has zero connections (portal create vs. paste ARM ID). `capability-host-bootstrap.md` got a new "Bring-your-own existing Azure resource (inline connection create)" section with per-category PUT body shapes, the 5-step resolution priority, and a note that `aiServices` is intentionally out of scope for inline create.

**Lesson learned:** Before proposing to soften a verdict, verify the platform constraint. "Azd doesn't support it" ≠ "platform doesn't support it." Capability hosts are a first-class GA surface; the only thing missing was the skillpack path to bootstrap them. Real remediation > verdict softening. Also: don't ship a "real fix" that only handles the populated-project case — the empty-project case is the more common entry point and is what BYO is designed for.

**RBAC is load-bearing — `--grant-rbac` flag (same release):** during live test of the BYO path against `agents-3iq-eastus2`, even with all 3 BYO connections created and verified, the project capabilityHost PUT reached `provisioningState=Failed` within ~3 minutes with no actionable diagnostic. Root cause: the project's SystemAssigned MI lacked data-plane RBAC on the backing Cosmos / Search / Storage resources. The platform uses the project MI (not the caller) to bootstrap containers/indexes/blobs during capHost provisioning — without those grants the bootstrap stalls and is reported as `Failed`. Recovery is destructive (DELETE the failed host + re-PUT) AND is blocked once any agent is linked to the failed host, so prevention is the only viable strategy.

The 6 required grants to the project MI (per MS Learn standard-agent-setup Phase 3 + Phase 5):

| # | Role                                  | Plane    | Backing | CLI surface                              |
|---|---------------------------------------|----------|---------|------------------------------------------|
| 1 | Cosmos DB Operator                    | Control  | Cosmos  | `az role assignment create`              |
| 2 | Cosmos DB Built-in Data Contributor   | **Data** | Cosmos  | `az cosmosdb sql role assignment create` (separate CLI surface; not visible to `az role assignment list`) |
| 3 | Search Service Contributor            | Control  | Search  | `az role assignment create`              |
| 4 | Search Index Data Contributor         | Data     | Search  | `az role assignment create`              |
| 5 | Storage Account Contributor           | Control  | Storage | `az role assignment create`              |
| 6 | Storage Blob Data Owner               | Data     | Storage | `az role assignment create`              |

`add-capability-host.sh` now accepts `--grant-rbac` which, before issuing the capabilityHost PUT, resolves the project MI principalId via `GET project` and issues all 6 grants idempotently (treats `RoleAssignmentExists` as success), then sleeps 30s for AAD propagation. New script Step 4b plans the grants (resolves per-role ARM IDs from `--<role>-resource-id` flags or from the existing connection's `metadata.ResourceId`). New script Step 7b executes them. Dry-run preview lists all 6 planned grants + target ARM IDs. New exit code 6 for grant failure. New KV outputs `GRANT_RBAC_STATUS=ok|skipped` + `GRANTS_COUNT=N`.

The prompt grew a new Step 2.5 ("Confirm RBAC posture") that explains the load-bearing finding and asks the user to pick: `grant` (recommended, sets `grant_rbac=true`), `already granted`, or `skip` (with a warning). New `grant_rbac` input. New forbidden shortcut: *"do not issue the capability-host PUT without verifying the 6 project-MI grants are in place"*. `capability-host-bootstrap.md` got a new "Required project-MI data-plane RBAC (load-bearing)" section with the canonical CLI block and a callout that the Cosmos data-plane role uses a different CLI surface than ARM role assignments. New troubleshooting row covering the `Failed` symptom + the "destructive AND blocked once an agent is linked" recovery wall.

**Lesson learned (RBAC):** ARM role assignments resolve `--assignee <objId>` to `appId` form in the Principal column, which made it impossible to confirm grants by reading `az role assignment list --assignee <objId>` against the project MI's object ID (rows were keyed under the appId form). Always use `--assignee-object-id` to query and grant; the create command additionally requires `--assignee-principal-type ServicePrincipal` to disambiguate. The Cosmos data-plane role is the easy-to-miss gotcha — it doesn't appear in regular RBAC listings, lives only on the Cosmos account as a SQL role assignment, and is the single most common reason a freshly-provisioned project capabilityHost fails.

**Cross-ref to TD-32 / TD-33:** TD-32 surfaced the gap (capability hosts not assessed correctly + no remediation path), TD-33 made the assessment a single-call wrapper, TD-34 closes the loop with a real mutator that supports both "pick existing connection" and "BYO inline create from ARM ID", plus the `--grant-rbac` step that takes the project MI from "no roles" to "fully provisioned" without a second skill invocation. All three close under v0.26.0.

## TD-35 — Observability + evaluation unverified for a LangGraph hosted agent (OPEN — human-review backlog)

**What:** The observability ([7]) and evaluation/red-team ([6]) surfaces have only been exercised end-to-end against agent-framework / `azure-ai-projects`-native agents. The skillpack advertises LangGraph as a supported brownfield runtime (recipe 01 names `langgraph-chat-sample` as a fixture, and the brownfield code-scan recognizes LangGraph), but no test run has confirmed that:

1. OTel GenAI spans emitted by a LangGraph graph land in App Insights with the attributes the Agent Monitoring Dashboard expects (`gen_ai.*` span conventions, agent/run correlation IDs).
2. Continuous-evaluation rules created via `azure-ai-projects` actually sample and score traffic from a LangGraph-backed hosted agent (the rule binds to an agent/deployment; the LangGraph node boundary may not map cleanly to the run/thread shape the eval sampler keys on).
3. The cloud red-team scan targets a LangGraph hosted agent without the adapter swallowing or reshaping turns in a way that defeats the adversarial probes.

**Why this is debt:** "Supported runtime" + "crown-jewel outer-loop surfaces" is an implied compatibility claim we have not verified for the second-most-likely customer runtime. If LangGraph spans or eval bindings silently no-op, a customer following recipe 01 with the LangGraph fixture gets an empty Monitor dashboard and assumes the skillpack is broken.

**Acceptance (to close):** a recorded e2e run (added to `tests/e2e/`) that deploys the `langgraph-chat-sample` fixture as a hosted agent, drives traffic, and asserts (a) non-empty trace spans with the expected GenAI attributes in App Insights, (b) at least one continuous-eval run reaching status `Completed` with a score, and (c) one cloud red-team scan completing against it. Document any adapter/instrumentation shim required in `foundry-observability` / `foundry-evals`.

**Why deferred:** needs a live testbed run against the LangGraph fixture and is gated on the tester-track e2e harness maturing (see automation tracks doc). Human-reviewed item — revisit when LangGraph appears in a real consumer install or when the e2e harness can host non-native fixtures.

**Priority (2026-06-26, PO direction):** promoted to **this phase**. The live observability proof —
trigger the agent and confirm real traces in the Agent Monitoring Dashboard + App Insights — is
essential for the LangGraph runtime and is no longer indefinitely deferred. Paired with TD-37 (the
scenario vehicle) and gated only on the tester-track secrets/approval being wired.

**Cross-refs:** TD-8 (preview SDK surface drift on the eval APIs this would exercise), TD-9 (red-team region gating the scan in (c) must respect), `maintenance/foundry-dependency-map.md` stages [6]/[7].

## TD-36 — Rubric evaluator support (OPEN — triage intake, human-gated)

**Source:** upstream-watch §7 feature-candidate — a new first-party **Rubric evaluator** surfaced in the
Foundry evaluator catalog. Logged here (not auto-applied) per the human-in-the-loop process in
`maintenance/AUTOMATION.md` §7.

**What:** `foundry-evals` currently declares a fixed `BUILT_IN_EVALUATORS` set and wires
continuous/scheduled eval rules against it. Adopting Rubric means: confirm the canonical evaluator
id + required init params against the live `custom-evaluators` / evaluator-catalog doc, add it to the
known-evaluator set in `_common.py`, allow it in `ensure_continuous_eval.py` / `ensure_scheduled_eval.py`,
and document the grader/rubric input shape.

**Acceptance (to close):** (a) Rubric id + params verified against the live doc/SDK (not guessed);
(b) an eval rule using Rubric created + reaching `Completed` with a score on the testbed; (c) a
recipe/scenario note showing how a customer declares it in `agent-capabilities.yaml`.

**Why deferred:** preview evaluator surface (TD-8 churn risk); needs a live verification pass on the
tester track before it ships. Revisit at the next monthly review or when a consumer asks for it.

## TD-37 — LangGraph as a recipe-tester fixture/scenario (OPEN — triage intake, human-gated)

**Source:** upstream-watch §7 new-recipe/new-scenario candidate. Companion to TD-35 (which tracks the
*observability/eval* compatibility question); this entry tracks the *test vehicle* that would close it.

**What:** Add an executable tester-track scenario (`tests/e2e/scenarios/03-langgraph-*.yaml`) that
deploys the `langgraph-chat-sample` fixture as a hosted agent and drives the recipe-01 command
sequence, so LangGraph stops being "documented but unverified" (AUTOMATION.md §6). This is the
harness work TD-35's acceptance depends on (the harness must host a non-native fixture).

**Acceptance (to close):** scenario yaml lands; one green run through `e2e-test.yml` (with the
mandatory teardown); TD-35 assertions (a)/(b)/(c) become checkable from it.

**Why deferred:** gated on the tester-track CI (`e2e-test.yml`, just added) getting its testbed
secrets + protected-env approval wired, and on the harness supporting non-native fixtures. Human-
reviewed; sequence after the first green native scenario run.

**Priority (2026-06-26, PO direction):** **this phase**, paired with TD-35 — this is the executable
vehicle that makes TD-35's live observability assertions checkable.

## TD-38 — configure-rbac scenario (OPEN — this phase, highest test priority)

**Source:** product-owner direction 2026-06-26. `/configure-rbac` is the only never-driven command
that sits *under* every other scenario — the role/identity grants it issues are what make eval-rule
binding, capability-host data-plane access, and the agent managed identity work at all. Today it is
"documented but unverified" (AUTOMATION.md §6).

**What:** Add a tester-track scenario that exercises `/configure-rbac` against the testbed across the
agent components it touches — agent MI → model deployment, project MI → Cosmos/AI Search/Storage
data-plane roles, caller → Foundry account. Assert each role assignment lands at the correct scope
(idempotent re-run = no-op) and that a downstream component (e.g. an eval rule or a hosted-agent
invoke) succeeds *because* the grant is present. Test it **inside** the agent scenarios, not in
isolation, so the role→capability linkage is what's proven.

**Acceptance (to close):** scenario yaml lands; a green `e2e-test.yml` run that (a) creates the
expected role assignments (verified via `az role assignment list --assignee <id> --scope <scope>`),
(b) is idempotent on re-run, and (c) shows a dependent operation that was previously blocked now
succeeding. Teardown removes any test-only assignments.

**Why now:** it gates the trustworthiness of every other live scenario — an unverified RBAC step
means an eval/observability/capability-host pass could be silently relying on pre-existing grants.

**Cross-refs:** TD-35/TD-39 (both depend on correct data-plane grants), `foundry-roles` preflight
(F-O SP-identity fix), `maintenance/AUTOMATION.md` §6.

## TD-39 — add-capability-host lifecycle scenario (OPEN — this phase, dedicated + self-tearing)

**Source:** product-owner direction 2026-06-26. `/add-capability-host` provisions BYO memory/thread/
vector backing (Cosmos + AI Search + Storage, optionally APIM-fronted) and is the most expensive
command to test — so it gets its own manually-dispatched scenario, not a slot in the cheap path.

**Correction to the premise:** a capability host is **not** permanent. The API has no in-place
UPDATE — a `PUT` over an existing host returns `409` — so the supported way to change bindings is
**DELETE + recreate**, which `add-capability-host.sh --force-recreate` does (deletes, polls for
completion, re-PUTs). Re-testing therefore does **not** require destroying the whole Foundry project;
the full cost teardown simply deletes the project-scoped test resources (Cosmos/Search/APIM) that
`infra/cleanup-sweep.sh` already tags as ephemeral.

**What:** A dispatch-only scenario that (1) starts from a project with no capability host, (2) runs
`/add-capability-host` to wire account→project hosts against freshly-provisioned (or dedicated)
Cosmos + AI Search + Storage, (3) verifies the host resolves (agent memory/thread persists across a
turn), (4) optionally exercises `--force-recreate` to prove the DELETE+recreate path, then (5) tears
down all ephemeral backing resources via `cleanup-sweep.sh --apply`.

**Acceptance (to close):** green dispatch run with capability-host GET returning the bound
connections, a persisted-memory assertion across two turns, and a clean post-run sweep (no orphaned
Cosmos/Search/APIM). Document the create→verify→(recreate)→teardown flow in the scenario.

**Why dispatch-only:** provisioning Cosmos + AI Search + APIM is slow and billable; this must not run
on the monthly cheap cron — it is a maintainer-initiated pre-release check.

**Cross-refs:** `foundry-deploy/capability-host-bootstrap.md` (idempotency = DELETE+CREATE; `--force-recreate`),
TD-38 (the project MI data-plane grants this host needs), `infra/cleanup-sweep.sh`.
