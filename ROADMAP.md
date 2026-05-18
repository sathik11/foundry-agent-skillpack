# Roadmap

The skillpack is at **v0.20.0** (May 2026). What's next is sequenced by *value of unblocking* × *real cost of building*. Open follow-ons are tracked as `TD-N` entries in [foundry-agent-skillpack/TECHNICAL_DEBT.md](foundry-agent-skillpack/TECHNICAL_DEBT.md).

For the rendered version with cross-links, see the [docs site Roadmap page](docs/src/content/docs/roadmap.md).

---

## Shipped recently

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

## Next minor (v0.21)

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

