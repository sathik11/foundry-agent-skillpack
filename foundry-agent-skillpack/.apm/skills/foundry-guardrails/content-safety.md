# Layer 2 — Azure Content Safety

Managed classifier. ~150ms per call. Cascaded by middleware in `entry` mode.

## Provision

```bash
az cognitiveservices account create \
  -n my-cs -g <rg> \
  --kind ContentSafety --sku S0
```

## Grant agent identity

```bash
az role assignment create \
  --assignee-object-id <instance_identity.principal_id> \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope <CS resource id>
```

This is Phase B — only run **after** `azd up` creates the per-agent identity.

## Inject env var

Add to `agent.yaml` `environment_variables`:
```yaml
AZURE_CONTENT_SAFETY_ENDPOINT: https://my-cs.cognitiveservices.azure.com
```

Use env-var-only redeploy (no rebuild) — see [foundry-deploy/version-lifecycle.md](../foundry-deploy/version-lifecycle.md).

## Severity scale

| Score | Meaning |
|---|---|
| 0 | Safe |
| 2 | Low |
| **4** | Medium ← default block threshold |
| 6 | High |

## Graceful degradation

If `AZURE_CONTENT_SAFETY_ENDPOINT` is unset, the middleware returns `passed=True, mode="disabled"` and logs a span. The agent does NOT fail closed — be deliberate.

## Categories blocked

`Hate`, `SelfHarm`, `Sexual`, `Violence` — all four checked in parallel; any one ≥ threshold blocks.
