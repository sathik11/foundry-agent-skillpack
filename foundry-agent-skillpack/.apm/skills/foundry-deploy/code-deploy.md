# Source-Code Deploy (preview) — zip-based hosted agents

> **Preview surface — verify before relying.** This page covers the **source-code deploy** path for hosted agents (api-version `2025-11-15-preview`, `Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview`). It is an **alternative** to the container path documented in [scaffold.md](scaffold.md) + [rest-api.md](rest-api.md), not a replacement. `code_configuration` and `container_configuration` are mutually exclusive on a single agent version.
>
> Authoritative source: [Deploy a hosted agent from source code (preview)](https://learn.microsoft.com/azure/foundry/agents/how-to/deploy-hosted-agent-code) (read on every revision — capability still evolving).

## When to pick which

| You have… | Pick |
|---|---|
| Existing Dockerfile, custom base image, system packages, or non-Python runtime not on the supported list | **Container** — see [scaffold.md](scaffold.md) |
| Plain Python 3.13 / 3.14 or .NET 10 agent, no system packages, want Foundry to build the image | **Code (zip)** — this page |
| Need fastest cold-start iteration (`remote_build`) or air-gapped wheels (`bundled`) | **Code (zip)** |
| Air-gapped builds where the service can't reach PyPI / NuGet | **Code (zip)** with `dependency_resolution: bundled` |

The scaffold prompt asks this question explicitly — see `/plan-agent` Step 0c and `/prepare-deploy` Step 1.

## Manifest declaration

Add to `agent-capabilities.yaml`:

```yaml
agent_kind: hosted
deploy_mode: code                       # code | container — default 'container' (back-compat)
code:
  runtime: python_3_13                  # python_3_13 | python_3_14 | dotnet_10
  entry_point: main.py                  # Python: file path. .NET: published assembly name.
  dependency_resolution: remote_build   # remote_build (default) | bundled
  protocol: responses                   # responses | invocations
```

`/prepare-deploy` Step 1 forks on `deploy_mode`. Track H1 (container) validates Dockerfile + ContainerAgent schema; new **Track H-code** validates the zip layout + dependency strategy + runtime version match.

## Required preview header

Every mutating call (`POST /agents`, `POST /agents/{name}`, `POST /agents/{name}/versions`, `DELETE`) MUST send:

```
Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview
```

GET calls (status, list, version detail) do NOT require it. The `:logstream` endpoint does NOT require it.

Skillpack convention: every helper that calls these endpoints sources `FOUNDRY_FEATURES_HEADER` from a shared constant — never hard-code the value inline. See `scripts/foundry-features.sh` (TD-32 deliverable; if absent, inline literally).

## SDK surface — Python (`azure-ai-projects >= 2.2.0`)

```python
from azure.ai.projects import AIProjectClient
from azure.identity import DefaultAzureCredential
import hashlib, pathlib

project = AIProjectClient(
    endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
    credential=DefaultAzureCredential(),
    api_version="2025-11-15-preview",
    allow_preview=True,                 # REQUIRED for project.beta.*
)

zip_path = pathlib.Path("agent-code.zip")
sha = hashlib.sha256(zip_path.read_bytes()).hexdigest()

version = project.beta.agents.create_version_from_code(
    agent_name="my-code-agent",
    file_path=str(zip_path),
    metadata={
        "code_configuration": {
            "runtime": "python_3_13",
            "entry_point": ["python", "main.py"],
            "dependency_resolution": "remote_build",
        },
        "protocol_versions": [{"protocol": "responses", "version": "1.0.0"}],
        "cpu": "1.0", "memory": "2.0Gi",
        "environment_variables": {"MODEL_DEPLOYMENT_NAME": "gpt-4.1-mini"},
        "instance_identity": {"type": "system_assigned"},
    },
)
```

- `project.beta.agents.*` only exists on a client built with `allow_preview=True`. Reads (`get_version`, `list_versions`) still go through `project.agents.*`.
- `azure-ai-projects` pin for the code-deploy path: `>=2.2.0,<3`. The skillpack's caller-side floor remains `>=2.0.0` for prompts that only do reads — only bump the floor on machines that run the code-deploy helpers.
- The SHA-256 above is for human verification against the response header `x-ms-code-zip-sha256`. The SDK injects the header automatically when you pass `file_path=`.

## SDK surface — .NET 10 (`Azure.AI.Projects.Agents`)

```csharp
using Azure.AI.Projects.Agents;
using Azure.Identity;

#pragma warning disable AAIP001   // suppress preview-surface warning
var admin = new AgentAdministrationClient(
    endpoint: new Uri(Environment.GetEnvironmentVariable("FOUNDRY_PROJECT_ENDPOINT")!),
    credential: new DefaultAzureCredential());

admin.Pipeline.AddPolicy(new FeaturePolicy("CodeAgents=V1Preview,HostedAgents=V1Preview"),
                         HttpPipelinePosition.PerCall);

var version = admin.CreateAgentVersionFromCode(
    agentName: "my-code-agent",
    filePath: "agent-code.zip",
    metadata: BinaryData.FromObjectAsJson(new {
        code_configuration = new {
            runtime = "dotnet_10",
            entry_point = new[] { "dotnet", "MyAgent.dll" },
            dependency_resolution = "remote_build",
        },
        protocol_versions = new[] { new { protocol = "responses", version = "1.0.0" } },
        cpu = "1.0", memory = "2.0Gi",
    }));
```

## REST API

```bash
# Bearer (note --resource — code-deploy 401s without it)
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)

# SHA-256 (server stores this and echoes it back on download for drift detection)
SHA=$(sha256sum agent-code.zip | awk '{print $1}')

# Create (one-time per agent; requires x-ms-agent-name)
curl -X POST "$ENDPOINT/agents?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview" \
  -H "x-ms-agent-name: $AGENT" \
  -H "x-ms-code-zip-sha256: $SHA" \
  -F "metadata=@metadata.json;type=application/json" \
  -F "code=@agent-code.zip;type=application/zip;filename=$AGENT.zip"

# Update / new version (omit x-ms-agent-name; content-addressable dedup applies)
curl -X POST "$ENDPOINT/agents/$AGENT?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview" \
  -H "x-ms-code-zip-sha256: $SHA" \
  -F "metadata=@metadata.json;type=application/json" \
  -F "code=@agent-code.zip;type=application/zip;filename=$AGENT.zip"
```

### Multipart body shape

- **Two parts, in order**: `metadata` (`application/json`) + `code` (`application/zip` with `filename=<agent>.zip`).
- Agent name must start + end with alphanumeric, may contain hyphens, ≤ 63 chars.
- `x-ms-agent-name` header is required **only on Create**. Updates infer the name from the URL path.

## azd tooling

```bash
# Scaffold (asks runtime + entry point if omitted)
azd ai agent init \
  --deploy-mode code \
  --runtime python_3_13 \
  --entry-point main.py \
  --dep-resolution remote_build      # remote_build (default) | bundled

# Deploy
azd up
```

`azd ai agent init --deploy-mode code` was added alongside the preview. Earlier `azd ai agent` extension versions (< the version that introduced `--deploy-mode`) will silently scaffold the container path — `/prepare-deploy` Step 0 already enforces a minimum extension version; bump that floor if code-deploy is required for this project.

## Packaging

The zip MUST be **flat at the root** — no top-level wrapper folder. The single most common failure mode is `agent-code.zip → my-agent/main.py` instead of `agent-code.zip → main.py`. The service does not unwrap.

### Python — `remote_build` (default)

```
agent-code.zip
├── main.py
└── requirements.txt
```

Service runs `pip install -r requirements.txt` inside the container at provisioning time. No local pip step required.

### Python — `bundled`

```
agent-code.zip
├── main.py
├── requirements.txt          # kept for record-keeping; service won't re-resolve
└── packages/                 # EXTRACTED modules, NOT raw .whl files
    ├── azure/identity/__init__.py
    └── requests/__init__.py
```

Build the `packages/` tree with the Linux platform tag and runtime version that match `code.runtime`:

```bash
pip install -r requirements.txt \
    --target packages/ \
    --platform manylinux2014_x86_64 \
    --python-version 3.13 \
    --implementation cp \
    --only-binary=:all:

zip -r agent-code.zip main.py requirements.txt packages/
```

`--only-binary=:all:` forces wheels (no source builds). `--python-version` MUST match `code.runtime` exactly.

### .NET — `remote_build`

```
agent-code.zip
├── MyAgent.csproj
├── Program.cs
└── *.cs
```

Service runs `dotnet restore` + `dotnet publish` server-side. `entry_point` still names the **published** assembly (`["dotnet", "MyAgent.dll"]`).

### .NET — `bundled`

```
agent-code.zip
├── MyAgent.dll
├── MyAgent.runtimeconfig.json
└── ... (publish output, flat at root)
```

```bash
dotnet publish -c Release -r linux-x64 --self-contained false -o publish/
cd publish && zip -r ../agent-code.zip .
```

## Lifecycle

### Status transitions

`creating → active` (success) | `creating → failed` (terminal). Same as the container path, but `error.code` for `failed` is typically `CodeError`:

- `error.message` includes the final restore / compile error line (pip for Python, NuGet for .NET) + an exit code + an `aka.ms` troubleshooting link.
- **Container log streaming does NOT apply to provisioning failures** — the container never started. Read `error.message`. `:logstream` is only useful after the container has started (i.e., `424 session_not_ready` and other runtime issues).

### Content-addressable versioning

A new version is minted **only when the zip's SHA-256 OR the agent definition actually changes**. Identical reposts return the existing latest version (the response envelope's `versions.latest` does not advance).

**Implication for `/audit-drift`**: "no new version after redeploy" is the **expected** outcome when nothing changed, not a regression. The audit reconciler MUST compare:

1. Local zip SHA-256 → `x-ms-code-zip-sha256` echoed by `code:download`
2. Local `metadata.json` → server `agent.versions.latest.code_configuration`

`x-ms-agent-version` is returned on every download — when you omit `agent_version`, this header tells you which version "latest" resolves to.

### Download the deployed zip

```bash
# Latest
curl -O -J "$ENDPOINT/agents/$AGENT/code:download?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview" \
  -H "Accept: application/zip"

# Specific version
curl -O -J "$ENDPOINT/agents/$AGENT/code:download?api-version=2025-11-15-preview&agent_version=2" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview" \
  -H "Accept: application/zip"
```

Response headers to keep:
- `x-ms-agent-version` — version served (use when `agent_version` is omitted).
- `x-ms-code-zip-sha256` — server-stored SHA. Compare against local for drift detection.

Image-based agents return `409 AgentNotCodeBased` on this endpoint — see [foundry-failure-modes § F-27](../foundry-failure-modes/SKILL.md).

### Stream container logs

```bash
curl -N "$ENDPOINT/agents/$AGENT/sessions/<sessionId>:logstream?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Accept: text/event-stream"
```

`<sessionId>` is the value of `x-agent-session-id` returned by every invoke response (and by `424` / `500` invoke failures). The `:logstream` endpoint does NOT require the preview header.

### Delete

```bash
# Delete one version
curl -X DELETE "$ENDPOINT/agents/$AGENT/versions/1?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview"

# Delete agent + all versions (cascades to idle sessions, but NOT active ones)
curl -X DELETE "$ENDPOINT/agents/$AGENT?api-version=2025-11-15-preview" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview"

# Force-delete (cascades active sessions too — irreversible)
curl -X DELETE "$ENDPOINT/agents/$AGENT?api-version=2025-11-15-preview&force=true" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Foundry-Features: CodeAgents=V1Preview,HostedAgents=V1Preview"
```

Without `&force=true`, an agent with active sessions returns `409 conflict (Agent has active sessions)` — see [foundry-failure-modes § F-24](../foundry-failure-modes/SKILL.md).

## Limits

| Limit | Value |
|---|---|
| Maximum zip size (multipart upload) | 250 MB |
| Supported runtimes (preview) | `python_3_13`, `python_3_14`, `dotnet_10` |
| `cpu` / `memory` | Must be a valid sandbox-size pair — see [Hosted-agent sandbox sizes](https://learn.microsoft.com/azure/foundry/agents/concepts/hosted-agents#sandbox-sizes) |

## RBAC

Same identity model as container hosted agents (TD-30 closure applies):

- **Caller** needs `Foundry Project Manager` at project scope to deploy a code-based hosted agent.
- **The agent's platform-assigned managed identity** needs `Foundry User` at project scope to call models from inside the container. The platform assigns this MI automatically — no caller action.

If `401 Unauthorized` is returned on Create/Update, the most common cause is the wrong token resource — see [foundry-failure-modes § F-28](../foundry-failure-modes/SKILL.md). If `403 Forbidden`, run `.agents/skills/foundry-roles/scripts/preflight-role.sh project foundry-user <sub> <rg> <account> <project>` (or `foundry-project-manager` for callers).

## Failure modes specific to this path

| Code | Where | Page |
|---|---|---|
| `F-21` | `400 CPU/Memory must be a valid resource tier` on Create/Update | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |
| `F-22` | `400 Agent version is still being provisioned` on invoke during version swap | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |
| `F-23` | `424 session_not_ready` — readiness probe never returned 200 | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |
| `F-24` | `409 conflict (Agent has active sessions)` on DELETE | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |
| `F-25` | Version stuck in `creating` > 10 min (`remote_build`) | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |
| `F-26` | `ModuleNotFoundError` at runtime | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |
| `F-27` | `409 AgentNotCodeBased` on `code:download` | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |
| `F-28` | `401 Unauthorized` on agent CRUD — missing `--resource https://ai.azure.com` | [foundry-failure-modes](../foundry-failure-modes/SKILL.md) |

## Cross-skill

- Container path (the original) — [scaffold.md](scaffold.md) + [rest-api.md](rest-api.md)
- Caller-side dependency floor change (`azure-ai-projects >=2.2.0` only on code-deploy machines) — [runtime-dependencies.md](runtime-dependencies.md)
- Capability gates in the manifest — [capabilities-manifest.md](capabilities-manifest.md)
- RBAC preflight — [foundry-roles](../foundry-roles/SKILL.md), [foundry-identity](../foundry-identity/SKILL.md)
