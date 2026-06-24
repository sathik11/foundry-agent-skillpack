#!/usr/bin/env bash
# token.sh — print a fresh Azure AD access token for the Foundry data plane, or `export`
# it as FOUNDRY_API_KEY (which the codex `foundry` provider reads). Token lifetime ~60-90 min.
#
#   eval "$(tests/e2e/driver/token.sh --export)"   # sets FOUNDRY_API_KEY in the shell
#   FOUNDRY_API_KEY=$(tests/e2e/driver/token.sh)    # capture
#
# Requires an active az login (SP via OIDC/secret in CI, or `az login` locally) with the
# Cognitive Services User / OpenAI User role on the driver-model account.
set -euo pipefail
SCOPE="https://cognitiveservices.azure.com/.default"
TOKEN="$(az account get-access-token --scope "$SCOPE" --query accessToken -o tsv)"
if [ "${1:-}" = "--export" ]; then
  printf 'export FOUNDRY_API_KEY=%q\n' "$TOKEN"
else
  printf '%s' "$TOKEN"
fi
