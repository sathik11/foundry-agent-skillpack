# E2E Driver Setup (W3) — concise

The **driver** is the "human surrogate": an agentic CLI that runs the skillpack `/commands` like a
real user, wrapped by `run_driver.py` with anti-loop / anti-stall guardrails. Maintainer/CI-only.

## Driver brain (Azure AI Foundry)

| Item | Value |
|---|---|
| Endpoint | `https://ai-account-o57kln2gc73hk.services.ai.azure.com/openai/v1` |
| API | Responses API (`/responses`) |
| Models deployed | `gpt-5.4` (default), `gpt-5.3-codex` |
| Auth | Azure AD token (no static key) via `az account get-access-token --scope https://cognitiveservices.azure.com/.default` |
| Access | test SP has **Cognitive Services User** at subscription scope |

## Backend: opencode (default) — chosen for model flexibility

**Decision:** opencode is the default backend (model-agnostic via models.dev — can later switch to
Claude / OSS-weight / other Azure models with a config edit). **codex** is retained as `--backend codex`.

> Foundry reasoning models (`gpt-5.4`, `gpt-5.3-codex`) reject the chat-completions `max_tokens`
> param, so opencode must use the **`@ai-sdk/openai` provider (Responses API)**, not
> `@ai-sdk/openai-compatible`. `configure-opencode.sh` writes the correct config.

```bash
npm install -g opencode-ai            # one-time
bash tests/e2e/driver/configure-opencode.sh   # writes ~/.config/opencode/opencode.json with a FRESH token
```

codex alternative:
```bash
npm install -g @openai/codex
# uses ~/.codex/config.toml (see codex-config.reference.toml) + FOUNDRY_API_KEY env
```

## Run the guarded driver

```bash
export FOUNDRY_API_KEY=$(tests/e2e/driver/token.sh)        # fresh AAD token (also used by codex)
bash tests/e2e/driver/configure-opencode.sh                # refresh opencode token (opencode only)

python3 tests/e2e/driver/run_driver.py \
  --backend opencode --model foundry/gpt-5.4 \
  --prompt-file tests/e2e/scenarios/<scenario>.md \
  --workdir <agent-repo> \
  --artifacts tests/e2e/artifacts/<run-id> \
  --wall-clock 2400 --no-progress 1200 --loop-threshold 4
```

Outputs `tests/e2e/artifacts/<run-id>/{transcript.jsonl, verdict.json}`.
Driver verdicts: `completed | failed | timeout | stalled | looped`.

## Guardrails (the "agent loops / loses track" fix)

| Guard | Default | Purpose |
|---|---|---|
| wall-clock | 2400s | hard total cap |
| no-progress watchdog | 1200s | kill if no event; generous so a long `azd up` is not a false stall (see W3-T3 / COSTS.md timeouts) |
| loop detector | 4 | kill on identical-command repeat or 2-command oscillation |

Validated: `python tests/e2e/driver/test_guardrails.py` (deterministic, both backends).
Live smoke: opencode + codex both returned through the wrapper against Foundry gpt-5.4.

## Auth note for CI

The workflow logs in with the SP (`AZURE_CREDENTIALS`), then `token.sh` / `configure-opencode.sh`
mint the data-plane token. Tokens expire ~60–90 min — re-run `configure-opencode.sh` per session.
The SP needs `Cognitive Services User`/`OpenAI User` on the driver-model account (it has it at
subscription scope today).
