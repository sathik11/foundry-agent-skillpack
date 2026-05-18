# Capability Gates (Phase A / B / C)

Called by `/prepare-deploy`, `/configure-rbac`, `/verify-agent` when `agent-capabilities.yaml` declares `guardrails.enabled: true`.

## Phase A — Preflight (before `azd up`)

### Hosted (Track A/B)
1. `main.py` imports and uses `GuardrailAgentMiddleware` with the declared `middleware_mode`.
2. `guardrails.py` is vendored into the agent folder (each agent gets its own copy).
3. If `layers` includes `content_safety`:
   - Foundry connection `content_safety.connection_name` exists (`mcp_foundry_mcp_project_connection_get`).
   - Env var `AZURE_CONTENT_SAFETY_ENDPOINT` is in `agent.yaml` `environment_variables` (or will be injected via env-var-only redeploy after Phase B).
4. **If `layers` includes `purview_dlp`** — see [purview-dlp.md § Phase A](purview-dlp.md):
   - `purview.enabled: true` is also declared (DLP without audit is meaningless).
   - `purview_dlp.policies[]` is non-empty.
   - `purview_dlp_middleware.py` is vendored into the agent folder.
   - `main.py` imports and uses `PurviewDLPMiddleware` after `GuardrailAgentMiddleware`.
   - If `enforcement_mode: block` — require `AGREE_PURVIEW_DLP_PREVIEW=1` env var on the agent version (constructor refuses without it).
5. If `redteam.gate_in_ci: true`: a CI workflow exists running PyRIT and failing on `*_asr > max_attack_success_rate`. Print [scripts/redteam.yml](scripts/redteam.yml) if not.

### Prompt (Track C)
Prompt agents have **no middleware path**. If `guardrails.enabled: true` and `agent_kind: prompt`, STOP and tell the user: layer-1 middleware is not available; rely on Content Safety (auto-applied by Foundry) + continuous evals.

## Phase B — Post-deploy RBAC (after `azd up`)

If `layers` includes `content_safety`:
```bash
./scripts/grant-cs-access.sh <agent_name> <cs_resource_id>
# (wraps the az role assignment create from content-safety.md)
```
Then env-var-only redeploy with `AZURE_CONTENT_SAFETY_ENDPOINT` set.

If `layers` includes `purview_dlp`:
```bash
./scripts/grant-purview-dlp-access.sh <agent_name>
# Tenant-scoped grants — emits a runbook for Tenant Admin in most cases.
# See purview-dlp.md § Required RBAC.
```

## Phase C — Verify

1. **Middleware spans:**
   ```kql
   dependencies
   | where cloud_RoleName == "<agent_name>"
   | where name startswith "guardrail."
   | summarize count() by tostring(customDimensions.["guardrail.layer"])
   ```
   Expect ≥ 1 entry per declared layer (`length`, `jailbreak`, `xpia`, `content_safety`, `purview_dlp`). KQL also in [scripts/kql/guardrail-spans.kql](scripts/kql/guardrail-spans.kql).

2. **Known-blocked sample test:** invoke with a deliberately-blocked input from this skill's test set; assert the response contains the refusal token configured in `guardrails.py`. Track P: assert Content Safety returned `severity >= threshold`.

3. **Purview DLP smoke (when declared):** send a deliberately-PII-bearing prompt; verify the appropriate `guardrail.purview_dlp.*` span attributes (`decision`, `sits`, `policy_id`). For `block` mode, also verify `AIPolicyBlocked` event in Purview Audit (~30 min lag).

4. **Red-team CI status (if `gate_in_ci`):** check the most recent workflow run; assert `*_asr <= max_attack_success_rate`.
