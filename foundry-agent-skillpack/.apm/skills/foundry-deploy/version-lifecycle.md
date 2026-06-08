# Version Lifecycle

> **Two paths.** This page is written for the container path (`deploy_mode: container`). Most of it (states, env-var-only redeploy, rollback) applies equally to the source-code (zip) path — with one critical difference: code-deploy uses **content-addressable versioning** (see below). Read this page first, then [code-deploy.md](code-deploy.md) for the zip-specific surface.

## States

`creating` → `active` (success) | `failed` (terminal)

For the code-deploy path, `failed` is typically `error.code: CodeError` with `error.message` containing the underlying pip / NuGet restore line plus an `aka.ms` link. Container log streaming (`:logstream`) does NOT apply to provisioning failures — the container never started — read `error.message` instead.

## Content-addressable versioning (code-deploy path only)

For `deploy_mode: code` POSTs to `/agents/{name}` or `/agents/{name}/versions`, the service mints a new version **only when the zip's SHA-256 OR the agent definition actually changes**. Identical reposts return the existing latest version — `versions.latest` does NOT advance.

**Audit implication.** "No new version after redeploy" is **expected** when nothing changed, not a regression. `/audit-drift` MUST compare:

1. Local zip SHA-256 → `x-ms-code-zip-sha256` header on `GET .../code:download`
2. Local `metadata.json` → server `versions.latest.code_configuration`

The container path does NOT have this dedup — every POST mints a new version regardless of whether the image tag changed (which is why the convention is to use timestamped tags).

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
