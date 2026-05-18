# REST API (`api-version=v1`)

> APM only **validates** these calls. The `azd ai agent` extension owns the actual writes.
> Use this doc to debug failures or to script ad-hoc operations outside `azd`.

## Required header (all calls)

```
Foundry-Features: HostedAgents=V1Preview
```

## Endpoints

| Op | Method + Path |
|---|---|
| Create agent (one-time) | `POST /agents` body `{"name": "<name>-v3"}` |
| Create version | `POST /agents/{name}/versions` body = ContainerAgent definition |
| Poll status | `GET /agents/{name}/versions/{ver}` (every 20s until `active`/`failed`) |
| Invoke | `POST /agents/{name}/endpoint/protocols/openai/responses?api-version=v1` |
| List | `GET /agents`, `GET /agents/{name}/versions` |

## Get the bearer

```bash
TOKEN=$(az account get-access-token --resource https://ai.azure.com --query accessToken -o tsv)
curl -H "Authorization: Bearer $TOKEN" \
     -H "Foundry-Features: HostedAgents=V1Preview" \
     "$EP/agents?api-version=v1"
```

## ContainerAgent definition (version body)

```jsonc
{
  "image": "<acr>.azurecr.io/<name>:2026-05-08-1234",
  "cpu": "1.0", "memory": "2.0Gi",
  "environment_variables": {
    "MODEL_DEPLOYMENT_NAME": "gpt-5.4-mini-1",
    "ENABLE_INSTRUMENTATION": "true"
  },
  "instance_identity": { "type": "system_assigned" }
}
```

## Critical rules

- Versions are **immutable** — always POST new, never PATCH
- `environment_variables` is **full-replace** — every POST must include ALL vars
- Failed versions don't auto-retry — POST a new version after fixing
- Use timestamped image tags (`2026-05-08-1234`), never `latest`
- `enableVnextExperience` flag is **deprecated** post-2026-04-22 — do not set
