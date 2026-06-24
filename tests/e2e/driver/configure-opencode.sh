#!/usr/bin/env bash
# configure-opencode.sh — write ~/.config/opencode/opencode.json for the Foundry driver brain
# with a FRESH Azure AD token as the apiKey. Run before each driver session (tokens expire ~60-90m).
#
# Uses the @ai-sdk/openai provider (Responses API) — required because Foundry reasoning models
# (gpt-5.4 / gpt-5.3-codex) reject the chat-completions `max_tokens` param that the
# openai-compatible provider sends; the Responses API path works cleanly.
#
# Env overrides: FOUNDRY_BASE_URL (default below), OPENCODE_CONFIG (default ~/.config/opencode/opencode.json)
set -euo pipefail
BASE_URL="${FOUNDRY_BASE_URL:-https://ai-account-o57kln2gc73hk.services.ai.azure.com/openai/v1}"
CFG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
mkdir -p "$(dirname "$CFG")"
TOKEN="$(az account get-access-token --scope https://cognitiveservices.azure.com/.default --query accessToken -o tsv)"
python3 - "$TOKEN" "$BASE_URL" "$CFG" <<'PY'
import json, sys
tok, base, cfg = sys.argv[1], sys.argv[2], sys.argv[3]
doc = {
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "foundry": {
      "npm": "@ai-sdk/openai",
      "name": "Azure AI Foundry (skillpack E2E driver)",
      "options": {"baseURL": base, "apiKey": tok},
      "models": {
        "gpt-5.4": {"name": "gpt-5.4"},
        "gpt-5.3-codex": {"name": "gpt-5.3-codex"}
      }
    }
  }
}
open(cfg, "w").write(json.dumps(doc, indent=2))
print(f"[opencode] wrote {cfg} (provider=foundry, models: gpt-5.4, gpt-5.3-codex)")
PY
