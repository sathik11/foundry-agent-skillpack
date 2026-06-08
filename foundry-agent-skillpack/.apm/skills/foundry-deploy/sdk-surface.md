# SDK Surface

```python
from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential

client = FoundryChatClient(
    project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],  # auto-injected by Foundry
    model=os.environ["MODEL_DEPLOYMENT_NAME"],
    credential=DefaultAzureCredential(),
)
agent = Agent(
    client=client,
    name="<Name>",
    instructions=INSTRUCTIONS,
    tools=[...],
    middleware=[...],
    default_options={"store": False},
)
ResponsesHostServer(agent).run()
```

## Pinned versions

| Package | Pin |
|---|---|
| `agent-framework` | `>=1.2.2` |
| `agent-framework-foundry-hosting` | `==1.0.0a260429` (alpha — exact pin) |
| `azure-identity` | `<1.26.0a0` |

Looser pins on the alpha package WILL break — the alpha API surface changed between `a260415` and `a260429`.

## Required env vars (auto-injected by Foundry)

- `FOUNDRY_PROJECT_ENDPOINT`
- `MODEL_DEPLOYMENT_NAME`
- `APPLICATIONINSIGHTS_CONNECTION_STRING` (when monitoring enabled)

Reserved prefixes — do NOT set in `agent.yaml`:
- `FOUNDRY_*`, `AGENT_*`, `APPLICATIONINSIGHTS_*` → returns 400 if you set them.

## Anti-pattern: `FoundryAgent` class

`FoundryAgent` (agent-framework v1.1.1) silently no-ops in the refreshed preview because it injects `extra_body={"agent_reference": ...}` — the deprecated initial-preview pattern. Use the client-swap pattern above instead.

## Code-deploy SDK surface (preview)

The code-deploy (zip) path uses a **different** client surface — `project.beta.agents.create_version_from_code` / `download_code` on `AIProjectClient`. Requires `azure-ai-projects>=2.2.0` and `allow_preview=True` on the client. Read [code-deploy.md § SDK surface](code-deploy.md#sdk-surface--python-azure-ai-projects--220) for the full pattern. `project.agents.*` (no `beta`) remains the correct surface for reads (`get_version`, `list_versions`, `delete`).
