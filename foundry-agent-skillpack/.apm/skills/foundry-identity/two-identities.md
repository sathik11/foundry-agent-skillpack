# Two-Identity Model

| Identity | Purpose | How to get |
|----------|---------|-----------|
| **Project MI** | Image pull from ACR + project operations | ARM API on the project resource |
| **Per-agent identity** | Runtime: model inference, data access, tools | `azd ai agent show --output json` → `instance_identity.principal_id` (or `GET /agents/{name}/versions/{ver}` from REST) |

The per-agent identity is an `agent`-subtype Service Principal in Entra (post 2026-04-22). It is **reused across versions of the same agent** — grant once, all future versions inherit.

## Get them

```bash
# Project MI
PROJECT_MI=$(az rest --method get \
  --uri "https://management.azure.com/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.CognitiveServices/accounts/<account>/projects/<project>?api-version=2026-03-01" \
  --query identity.principalId -o tsv)

# Per-agent
AGENT_PRINCIPAL=$(azd ai agent show --name <agent_name> --output json \
  | jq -r '.instance_identity.principal_id')
```

The reusable wrapper: [scripts/check-identities.sh](scripts/check-identities.sh).

## Do NOT

- Use `blueprint.principal_id` for RBAC → `PrincipalTypeNotSupported`
- Assume Toolbox-success means direct-read works (different identities)
- Forget account-scope grants (project-only is insufficient for model access)
- Try to grant per-agent grants pre-`azd up` — the principal does not exist yet
