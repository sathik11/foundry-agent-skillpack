# Version Lifecycle

## States

`creating` → `active` (success) | `failed` (terminal)

## Env-var-only redeploy

Reuse the existing image tag, change only `environment_variables` in the POST body.
Activation: ~20s vs ~10 min for full image rebuild.

Use cases:
- Toggle `ENABLE_INSTRUMENTATION`
- Inject `AZURE_CONTENT_SAFETY_ENDPOINT` after Phase B RBAC
- Swap `MODEL_DEPLOYMENT_NAME` between deployments of the same model family

## Code-change redeploy

1. Bump image tag
2. `az acr build` (or let `azd up` do it)
3. POST new version

## Rollback

There is no `rollback` API. To roll back:
1. Find the last-known-good version: `GET /agents/{name}/versions`
2. POST a new version with the same `image` tag and `environment_variables`
3. The new version supersedes the broken one

## Multiple active versions

Foundry supports multiple `active` versions per agent. Traffic-splitting is **not** in the public preview — the latest `active` version receives all traffic.
