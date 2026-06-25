# Changelog — foundry-agent-skillpack

Concise, customer-facing release notes. One short block per release: what changed and why it
matters. Format follows [Keep a Changelog](https://keepachangelog.com/); versions are
[SemVer](https://semver.org/).

**Convention (read before cutting a release):**
- Every package release MUST add a dated section here with a **concise** summary — 3–6 bullets
  max, customer-impact framing, no internal play-by-play.
- Group bullets under `Added` / `Changed` / `Fixed` / `Deprecated` as needed.
- The verbose engineering rationale stays in `apm.yml` header comments and `TECHNICAL_DEBT.md` —
  do **not** duplicate that depth here.
- A release is only cut when the tester track is green (see `maintenance/AUTOMATION.md` §3).
- Keep an `[Unreleased]` section at the top; move it under the new version + date at release.

## [Unreleased]

### Fixed
- Removed stale Foundry **classic-portal** doc reference; observability now points at the new
  Foundry portal **Agent Monitoring Dashboard** (`/azure/foundry/observability/...`).
- Corrected the eval **region** model: only cloud red-team + hosted risk/safety evaluators are
  region-limited; batch/quality evals (continuous + scheduled) are broadly available incl.
  `westus`. Red-team region check is now **advisory** (bypass via `--dry-run` or
  `REDTEAM_ALLOW_UNSUPPORTED_REGION=1`); region set refreshed (adds `australiaeast`).

### Added
- `maintenance/AUTOMATION.md` — maintainer map of the two automation tracks, slash-command
  sequence, codebase segregation, and skill interdependency/overlap visuals.
- Per-run **P0 freshness** preflight for crown-jewel surfaces (guardrails, observability,
  evals, APIM gateway) in the dependency map + `doc-sources.yaml`.
- Tester-track CI (`.github/workflows/e2e-test.yml`) with **mandatory Foundry resource teardown**
  on every outcome; rolling **triage issue** so new features/recipes/scenarios reach the PO
  without blocking the scheduled watcher.

### Changed
- Docs site is now **release-gated** — published after a package release (or manual dispatch),
  not on every push to `main`.
- Upstream watcher cadence split: detection stays twice-weekly; **apply/package review is monthly**.


### Debt
- TD-35 — observability + evaluation **unverified for a LangGraph hosted agent** (human-review).
- TD-28 extended — cross-OS scripts: documented the costly **MCP-fallback loop** on Windows.

## [0.27.0] — 2026-06-xx

### Changed
- **Deploy approvals collapsed** from ~12 to ≤4 before `azd up` via a composite
  `prepare-deploy.sh` wrapper (FB-14).
- **`azd up` correctness**: manifest-aware `safe-azd-init.sh` forks on `deploy_mode`
  (container vs code), passes `--location` to prevent cross-region drift, and refuses
  contradictory manifests (FB-15/18/20/21).

### Fixed
- Closed 21 Round-1 dogfood feedback entries (FB-1 … FB-21); replaced inline azd/az/jq/curl
  plumbing with named scripts that emit structured KV + `RECOVERY=` lines.

### Added
- New `foundry-deploy/versions.yaml` canonical version floors; `read-topology.sh`,
  `discover-acr.sh`, `probe-mcp-endpoint.sh` helper scripts.
- Failure modes F-29 (cross-region `InvalidResourceLocation`) and F-30 (`azd deploy`
  Dockerfile-not-found for `deploy_mode: code`).

## [0.26.0]

### Added
- `/assess-project` single-call topology discovery and `/add-capability-host` real
  remediation (account + project scope, BYO inline connection create, `--grant-rbac`).

## [0.24.0]

### Changed
- Foundry RBAC role rename handling (`Foundry User`/`Owner`/…); removed `Azure AI Developer`
  misuse.

## [0.23.0]

### Added
- `install-prereqs.sh` for the supported macOS / Linux / WSL2 path; documented Windows gap.

## [0.22.0]

### Added
- Inbound firewall coverage for Teams / M365 Copilot → private Foundry agent (APIM v2,
  `validate-jwt`, M365 service tags).

## [0.20.0]

### Added
- Teams publish orchestration; network detection walks NSGs / Azure Firewall / SEPs.

[Unreleased]: https://github.com/your-org/foundry-agent-skillpack/compare/v0.27.0...HEAD
