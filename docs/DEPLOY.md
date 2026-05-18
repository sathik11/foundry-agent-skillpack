# Deploy the docs site to Azure Static Web Apps

The docs site under `docs/` is an Astro Starlight project. The CI workflow at
[`.github/workflows/docs.yml`](../.github/workflows/docs.yml) builds it and pushes to Azure Static Web Apps on every push to `main` (and per-PR previews).

This guide is the one-time SWA setup.

## Prerequisites

- Azure subscription where you'll host the SWA.
- `Contributor` on the resource group you'll create the SWA in.
- A GitHub repository write secret you can set: `AZURE_STATIC_WEB_APPS_API_TOKEN`.

## Steps

### 1. Create the SWA in Azure

Via Azure CLI:

```bash
SUB="<your-subscription-id>"
RG="rg-foundry-agent-skillpack-docs"
LOC="centralus"   # or another SWA-supported region
NAME="foundry-agent-skillpack-docs"

az login
az account set --subscription "$SUB"
az group create --name "$RG" --location "$LOC"

az staticwebapp create \
  --name "$NAME" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Free
```

The Free tier is fine for docs sites — 100GB bandwidth/month, custom domain, free SSL.

### 2. Get the deployment token

```bash
az staticwebapp secrets list \
  --name "$NAME" --resource-group "$RG" \
  --query 'properties.apiKey' -o tsv
```

Copy the output. This is the `AZURE_STATIC_WEB_APPS_API_TOKEN` value.

### 3. Add it as a repo secret

In GitHub: **Settings → Secrets and variables → Actions → New repository secret**.

- **Name:** `AZURE_STATIC_WEB_APPS_API_TOKEN`
- **Value:** the token from step 2

### 4. Set the site URL in `astro.config.mjs`

Update `site:` in [`docs/astro.config.mjs`](astro.config.mjs) to the URL Azure assigned (or your custom domain).

```bash
az staticwebapp show \
  --name "$NAME" --resource-group "$RG" \
  --query 'defaultHostname' -o tsv
# → e.g. brave-flower-12345abc.5.azurestaticapps.net
```

Edit `docs/astro.config.mjs`:

```javascript
export default defineConfig({
  site: 'https://brave-flower-12345abc.5.azurestaticapps.net',
  // ...
});
```

### 5. Push to main

The `docs.yml` workflow fires on push and:

1. Sets up Node 20 + npm cache.
2. Installs deps (`npm ci` if `package-lock.json` exists, else `npm install`).
3. Builds with `npm run build` → output to `docs/dist/`.
4. Uploads `docs/dist/` to your SWA via the `Azure/static-web-apps-deploy` action.

Per-PR builds get a preview URL commented on the PR by the SWA action.

## Custom domain (optional)

```bash
az staticwebapp hostname set \
  --name "$NAME" --resource-group "$RG" \
  --hostname docs.foundry-agent-skillpack.example.com
```

DNS: add a `CNAME` record pointing your custom hostname to the SWA's `defaultHostname`. Azure auto-provisions SSL.

## Local preview (no deploy)

```bash
cd docs
npm install
npm run dev          # → http://localhost:4321
npm run build        # → produces ./dist/
npm run preview      # serves ./dist/
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Workflow fails at `Deploy to Azure Static Web Apps` with 401 | Token wrong / expired | Re-run step 2 + 3; tokens rotate when you redeploy SWA |
| Site shows 404 on every page | `output_location` mismatch — the workflow uploads `docs/dist/` because we `skip_app_build: true` | Don't change those flags; the Astro build is already done before the SWA action runs |
| PR comment with preview URL never appears | `pull-requests: write` permission missing on the workflow | Already set in `docs.yml`; check repo settings haven't overridden it |
| Sidebar items not showing | Page slug doesn't match `astro.config.mjs` `sidebar.items[].slug` | Slugs are filenames without extension, relative to `src/content/docs/` |

## Cost

Free tier: $0/month for personal docs sites. If you exceed bandwidth or need staging environments, Standard tier is ~$9/month per app.

## Read next

- [Astro Starlight docs](https://starlight.astro.build/) — for theming, components, and content collection config.
- [Azure SWA docs](https://learn.microsoft.com/azure/static-web-apps/) — for custom domains, auth, and routing.
