---
name: foundry-failure-modes
description: 34 verified failure modes (incl. code-deploy preview + cross-region + deploy-mode mismatch) with symptom-to-fix lookup for Foundry hosted agents
---

# Foundry Failure Modes

## Quick Triage

| Symptom | Check | Fix |
|---------|-------|-----|
| 400 on version create | Env var prefix or missing metadata | Remove `FOUNDRY_*`/`AGENT_*` prefixes |
| Version `failed` | ImageError → AcrPull; other → docker test | Grant AcrPull to Project MI, POST new version |
| 403 at runtime | Instance MI roles at account scope | Grant `Foundry User` at **account** scope |
| Model 400 on sub-agent | Model mismatch | `SUBAGENT_MODELS` mapping per agent |
| Sync timeout | Pipeline >120s | Use `"stream": true` |
| Fabric returns 0 rows | NL2SQL non-determinism | Implement deterministic fallback |
| Tool name rejected | Dots in MCP name | Wrap in `@tool` with clean name |
| Stream cuts silently | LLM serialization bottleneck | Inter-tool data buffer |
| Sub-agent fails randomly | Transient platform errors | Retry 5x with exponential backoff |
| Eval shows "Failed" | No-data (not broken) | Generate traffic, next run picks it up |
| Teams `@mention` types but never replies (private Foundry) | Inbound chain missing OR reply FQDNs blocked | Stand up reverse proxy per [inbound-firewall.md](../foundry-teams-workiq/inbound-firewall.md); confirm `smba.trafficmanager.net` + `login.botframework.com` allow-listed |
| 401 on code-deploy create / `code:download` | Token issued for wrong audience | `az account get-access-token --resource https://ai.azure.com` (F-28) |
| Code version stuck in `creating` >10 min | `remote_build` can't resolve a dep | Switch to `dependency_resolution: bundled` (F-25) |
| `ModuleNotFoundError` at first invoke | Wrong wheel platform / raw `.whl` in `packages/` | Rebuild with `--platform manylinux2014_x86_64 --only-binary=:all:` (F-26) |
| Identical zip redeploy = no new version | Content-addressable dedup (expected) | Compare zip SHA-256 + manifest; not a regression |
| `azd up` `InvalidResourceLocation` / `LocationNotAvailableForResourceType` | Cross-region BYO: `AZURE_LOCATION` ≠ Foundry project region | `azd env set AZURE_LOCATION <target.location> && azd env set USE_EXISTING_AI_PROJECT true` (F-29) |
| `azd deploy` `No such file or directory: Dockerfile` (declared `deploy_mode: code`) | Extension silently scaffolded container path | Edit `azure.yaml` `language` to `py` or `dotnetcore` (F-30); re-run `/prepare-deploy` |
| Capability-host provision returns 403 on Cosmos / AI Search / Storage (looks like RBAC) | Foundry account is public but backing resource has `publicNetworkAccess=Disabled` (or vice-versa) | Match the network posture: flip backing resource to `publicNetworkAccess=Enabled`, or put both behind a PE/VNet (F-31) |

## Deployment Failures

- **F-01 `400 EnvVarReserved`**: Rename from `FOUNDRY_*` to your own prefix (e.g., `MYPROJECT_*`)
- **F-03 ImageError**: Grant `AcrPull` to Project MI on ACR. POST new version (failed ones don't retry)
- **F-04 PrincipalTypeNotSupported**: Use `instance_identity.principal_id`, NOT `blueprint.principal_id`
- **F-05 Health timeout**: Test locally with `docker run` — expect port 8088 within 25s

## Runtime Failures

- **F-06 Container boots then 403**: `Foundry User` missing at **account** scope (not just project)
- **F-07 Model 401/403**: `Cognitive Services OpenAI User` missing at account scope
- **F-08 Model mismatch 400**: `model` in request must exactly match sub-agent's configured model
- **F-09 120s sync timeout**: Use SSE streaming for multi-agent pipelines

## Data Access Failures

- **F-10 NL2SQL 0 rows**: Non-deterministic. Always have fallback.
- **F-11 Soft errors**: HTTP 200 but text says "unable to retrieve". String-match to detect.
- **F-12 MCP dots**: Toolbox namespaces as `server.tool` → 400. Wrap in `@tool`.
- **F-13 Toolbox works but direct read 403s**: Different identities (Project MI vs per-agent)

## SDK Failures

- **F-14 ImportError `_telemetry`**: Use `agent-framework-foundry-hosting==1.0.0a260429` or later
- **F-15 TextContent import**: Use `Message("assistant", [string])` instead
- **F-16 "usage not supported"**: Informational only — safe to ignore

## Multi-Agent Failures

- **F-17 Stream closes silently**: LLM serializing 20KB+ as tool argument. Use data buffer.
- **F-18 Intermittent 408/refused**: Retry 5x with 2s/4s/8s/8s backoff. All transient.
- **F-19 50KB+ server_error**: Truncate to 30 records before passing downstream.

## Publish / Channel Failures

- **F-20 Teams `@mention` succeeds, no reply** (silent publish, private Foundry):
  - **Symptom**: Bot installed in Teams, `@mention` shows typing indicator, reply never lands. No error in App Insights, no entry in Foundry trace, no 4xx anywhere obvious.
  - **Root cause (inbound leg)**: Foundry account has `publicNetworkAccess=Disabled` (or BYO VNet) and the Bot Service messaging endpoint points directly at the Foundry FQDN. Bot Framework Channel Adapter calls land on the public Microsoft backbone from the Teams service tag — they cannot reach a private endpoint. Foundry never sees the request.
  - **Root cause (outbound leg)**: Inbound chain is fine, agent processes the activity, but its egress firewall blocks `smba.trafficmanager.net` (the reply queue), so the reply is silently dropped.
  - **Fix**: Front the private agent with a customer-owned reverse proxy that validates the Bot Framework JWT and forwards to the Foundry PE. Paste-ready APIM v2 + VNet integration scaffold + decision matrix in [foundry-teams-workiq/inbound-firewall.md](../foundry-teams-workiq/inbound-firewall.md). Verify with `probe-inbound-chain.sh <agent_path> <custom_domain>` (3 probes; non-zero exit on any deviation).
  - **Allowlist `smba.trafficmanager.net` + `login.botframework.com`** on the agent's egress firewall before declaring health — see [foundry-prod-readiness/networking.md § Firewall allowlist](../foundry-prod-readiness/networking.md#firewall-allowlist-byo-vnet--azure-firewall).

## Source-code Deploy (preview) Failures

See [foundry-deploy/code-deploy.md](../foundry-deploy/code-deploy.md) for the full preview surface. These eight modes only apply when `agent-capabilities.yaml deploy_mode: code`.

- **F-21 `400 CPU and Memory must be specified as a valid resource tier`** on Create/Update: `cpu` / `memory` in `metadata.json` are not a recognized sandbox-size pair. Pick from [Hosted-agent sandbox sizes](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#sandbox-sizes); commonly `cpu: "1.0", memory: "2.0Gi"` for small agents.
- **F-22 `400 Agent version is still being provisioned`** on invoke: an invoke landed during a version swap. Poll `GET /agents/{name}?api-version=2025-11-15-preview` until `versions.latest.status == "active"`, then retry. Skip during smoke tests immediately after deploy.
- **F-23 `424 session_not_ready`** on invoke: container started but the readiness probe never returned `200`. Capture `x-agent-session-id` from the 424 response and stream container logs via `GET $ENDPOINT/agents/$AGENT/sessions/<sessionId>:logstream?api-version=2025-11-15-preview` (no preview header needed). Most common cause: app crashes on import (missing env var, bad model deployment name, syntax error in `main.py`).
- **F-24 `409 conflict` on DELETE — `Agent has active sessions`**: the agent has in-flight sessions. To cascade-delete idle + active sessions, append `&force=true` to the DELETE URL. **Irreversible** — never use in CI on a shared environment without an explicit confirmation gate.
- **F-25 Code version stuck in `creating` >10 min** (`dependency_resolution: remote_build`): the service can't resolve a pip / NuGet dependency (private feed, network egress block, or a package that needs a system library). Switch to `dependency_resolution: bundled` and ship a prebuilt `packages/` (Python) or publish output (.NET). See [code-deploy.md § Packaging](../foundry-deploy/code-deploy.md#packaging).
- **F-26 `ModuleNotFoundError` at runtime** (`dependency_resolution: bundled`): wheels in `packages/` were built for the wrong platform/Python — typically Windows binaries or source-only packages on a Mac/Windows dev box. Rebuild from a Linux container or with the explicit platform tag:
  ```bash
  pip install -r requirements.txt --target packages/ \
    --platform manylinux2014_x86_64 --python-version 3.13 \
    --implementation cp --only-binary=:all:
  ```
  `--only-binary=:all:` forces wheels (no source builds). Verify `packages/` contains **extracted modules**, not raw `.whl` files (a common scripting bug — `pip download` produces `.whl`s, not what the runtime needs).
- **F-27 `409 AgentNotCodeBased`** on `GET .../code:download`: agent was deployed via `container_configuration` (Docker image), not `code_configuration`. There is no zip to download. Check `agent-status.json deploy.deploy_mode` — if it's `container`, use `azd ai agent show` + ACR pull instead.
- **F-28 `401 Unauthorized` on agent Create / Update / `code:download`**: token issued for the wrong audience. Foundry control-plane writes require an `https://ai.azure.com` audience token, NOT `https://management.azure.com`. Fix:
  ```bash
  TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
  ```
  If the call is `403 Forbidden` instead of `401`, see TD-30: caller needs `Foundry Project Manager` at project scope to deploy code-based agents. Run `.agents/skills/foundry-roles/scripts/preflight-role.sh project foundry-project-manager <sub> <rg> <account> <project>`.
- **F-29 `400 InvalidResourceLocation` / `LocationNotAvailableForResourceType`** during `azd up` provision (cross-region BYO project): `azd` defaulted `AZURE_LOCATION` to the **resource group's** region, but the Foundry account / project lives in a different region. `azd ai agent init` infers location from the RG and silently writes the wrong value into the env. Symptom: provision tries to create a Cognitive Services deployment in a region the model SKU isn't available in.
  - **Diagnose**: `azd env get-value AZURE_LOCATION` and compare with `target.location` in `agent-capabilities.yaml`.
  - **Fix**:
    ```bash
    azd env set AZURE_LOCATION <manifest.target.location>
    azd env set USE_EXISTING_AI_PROJECT true
    ```
    The `USE_EXISTING_AI_PROJECT=true` toggle is the documented opt-out from the project-creation Bicep — when the project already exists in another region, set this so `azd up` skips the create step entirely.
  - **Prevent**: the `prepare-deploy.sh` wrapper's `validate-azd-env-location.sh` stage catches this before `azd up` runs. If you skipped `/prepare-deploy`, re-run it.
- **F-30 `azd deploy` fails with `language: docker` mismatch / `No such file or directory: Dockerfile`** (declared `deploy_mode: code`): the current `azure.ai.agents` extension silently scaffolds the container path even when `--deploy-mode code` was on the init command, leaving `azure.yaml` `services.<svc>.language: docker` and a missing Dockerfile. Symptom: `azd up` provision succeeds, then `azd deploy` cannot find a Dockerfile to build.
  - **Diagnose**: `yq -r '.services.*.language' azure.yaml` and `ls Dockerfile`. If `language: docker` AND no Dockerfile AND manifest says `deploy_mode: code` → this is F-30.
  - **Fix**: edit `azure.yaml` to set `services.<svc>.language` to the correct value for the chosen runtime:
    - `python_3_13` / `python_3_14` → `language: py`
    - `dotnet_10` → `language: dotnetcore`
  - And ensure no `Dockerfile` is present in the agent folder (delete it or move to a different path — its presence will re-trigger the container scaffolder if you re-init).
  - **Prevent**: the `prepare-deploy.sh` wrapper's `validate-azure-yaml.sh` stage catches this. The rewritten `safe-azd-init.sh` (v0.27+) also refuses to run when `deploy_mode: code` is declared but a Dockerfile is present.
- **F-31 `403 Forbidden` on Cosmos / AI Search / Storage during capability-host provision (network mismatch masquerading as RBAC)**: capability-host PUT against `cosmos / search / storage` connections fails with a 403 that looks identical to a missing data-plane role assignment, but the actual cause is a `publicNetworkAccess` mismatch between the Foundry account/project and the backing resource. Wasted-investigation pattern: hours spent re-granting `Cosmos DB Built-in Data Contributor` / `Search Index Data Contributor` / `Storage Blob Data Owner` to the project MI before realising the role assignments were already correct.
  - **Two-sided rule**: Foundry account + project + every backing capability-host resource (Cosmos DB, AI Search, Storage) must share the **same** network posture. Either all public, or all on the same VNet / private endpoint path. A public Foundry account cannot bind a private-only backing resource (no egress route), and a private Foundry account cannot bind a public-only backing resource (data-plane TLS auth refuses the cross-class call).
  - **Diagnose**:
    ```bash
    # Foundry account posture
    az cognitiveservices account show -g <rg> -n <account> \
      --query 'properties.publicNetworkAccess' -o tsv
    # Backing resources posture (one liner — adjust resource type per backing)
    az cosmosdb show           -g <rg> -n <cosmos>  --query 'publicNetworkAccess' -o tsv
    az search service show     -g <rg> -n <search>  --query 'publicNetworkAccess' -o tsv
    az storage account show    -g <rg> -n <storage> --query 'publicNetworkAccess' -o tsv
    ```
    If the account is `Enabled` and any backing is `Disabled` (or vice-versa) → F-31.
  - **Fix (public account, accidentally-private backing — most common during Bicep drift)**:
    ```bash
    az cosmosdb update        -g <rg> -n <cosmos>  --public-network-access Enabled
    az search service update  -g <rg> -n <search>  --public-network-access Enabled
    az storage account update -g <rg> -n <storage> --public-network-access Enabled
    ```
    Wait ~60s for the network ACL to propagate, then re-run `add-capability-host.sh`.
  - **Fix (private account, accidentally-public backing — keep private)**: leave the backing private, add a private endpoint to it in the Foundry account's subnet/PE-pool, and confirm DNS resolves to the PE IP from the Foundry side. Do NOT flip the backing to public just to make the PUT succeed — that re-opens a data-egress hole the original network design intentionally closed.
  - **Prevent**: `/assess-project` Step 7 surfaces the network class for the account but does NOT today cross-check backing resources. Tracked as a verifier gap — until then, every brownfield onboarding should run the three `az ... show --query publicNetworkAccess` calls above before `/add-capability-host`.
  - **Why the 403 lies**: capability-host PUT runs as the project MI, so when the network layer rejects the data-plane handshake the platform-side AAD layer cannot distinguish "principal denied" from "TLS endpoint unreachable from this network class" and returns the safer of the two — `403`. There is no surfaced `WAF`/`network-acl` error code today.

