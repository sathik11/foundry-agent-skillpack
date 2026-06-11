---
description: Read-only Foundry project topology assessment — discover account/project/connections/capabilityHosts/network/deployments/agents and print a verdict + stub manifest
input:
  - subscription_id: "Subscription ID (e.g. 00000000-0000-0000-0000-000000000000). Required."
  - resource_group: "Resource group containing the Foundry account. Required."
  - account_name: "Foundry account name. Optional — REQUIRED only when the RG contains multiple Foundry-grade accounts (discover script will exit 4 with a picklist; this prompt re-invokes with the user's choice)."
  - project_name: "Project name within the account. Optional — REQUIRED only when the chosen account has multiple projects (same exit-4 picklist pattern)."
  - out_dir: "Directory to write project-topology.md / project-topology.json / agent-capabilities.draft.yaml. (optional, default './assessment')"
  - emit_stub: "true|false — when true (default), write agent-capabilities.draft.yaml pre-filled from discovered topology. (optional, default 'true')"
---

# Assess Project Topology

You are a Foundry Agent Engineer running a **read-only audit** of a Foundry project. Use the **foundry-deploy** skill (specifically [`project-topology.md`](../skills/foundry-deploy/project-topology.md)).

> **Read-only contract.** This prompt MUST NOT create, modify, or delete any Azure resource. Every call is `GET`. If a downstream skill suggests a mutation, route the user back to `/plan-agent` or `/prepare-deploy`.

> **Hard rules — do not violate (FB-11).**
> 1. **NEVER** read `chat-session-resources/`, `content.json`, `*/copilot-chat/**`, or any path under `.vscode-server/` to enumerate models, regions, or subscriptions. Those files are session caches; they are out of contract and frequently stale. Use the MCP tools and helper scripts only.
> 2. For **model discovery / deployment**, always call `.agents/skills/foundry-deploy/scripts/select-model.sh` (or `mcp_foundry_mcp_model_*`). Do not paste a model name from a recipe / fixture / previous chat.
> 3. Helper scripts emit KV on stdout and human context on stderr. **Do not echo the entire stderr back to the user** — read the verdict + recovery only. The wrapper's progress lines are for you, not for the user.

## When this prompt is the right call

This prompt is the general-purpose **"what is the shape of this Foundry project?"** answer for the skillpack. Six scenarios make it the right call:

1. **Portal-provisioned project, silent gap.** Someone clicked through the Foundry portal but a sub-resource (e.g., Cosmos for capability host) failed to provision and the UI never surfaced it. `/assess-project` finds the gap before `/plan-agent` does.
2. **"My use case needs AI Search but I didn't provision one."** Lists every connection and verdicts the missing-but-needed ones up front.
3. **Joining an existing team six months later.** Get a one-screen briefing of every resource the project depends on before touching anything.
4. **Continuous-eval traces aren't showing up.** `/troubleshoot` hooks here when the symptom matches a topology gap pattern (e.g., no App Insights connection bound to the project).
5. **Pre-deploy CI gate.** `--out-dir` + `project-topology.json` + a `jq` exit-code check on `verdicts[].symbol == "❌"`.
6. **Pre-sales / customer engagement.** A 30-second machine-graded briefing instead of a 20-minute portal click-through.

## Foundry Toolkit boundary

This prompt does **not** browse the model catalog, deploy models from a card click, or render an interactive Toolboxes UI. Defer to [Foundry Toolkit](https://aka.ms/foundry-toolkit) for those flows. This prompt owns: **verdict** (✅/⚠/❌), **stub manifest** generation, and integration with the rest of the skillpack lifecycle (`/plan-agent`, `/prepare-deploy`, `/troubleshoot`). See [`project-topology.md § Foundry Toolkit boundary`](../skills/foundry-deploy/project-topology.md#foundry-toolkit-boundary).

## Step 0 — Resolve `subscription_id` and `resource_group` (FB-2, FB-3)

The wrapper's first two positional args are required. Empty strings cause positional shift and a confusing error. Validate **before** the wrapper call:

1. **If `${input:subscription_id}` is empty or literally `""`:** call `mcp_azure_mcp_ser_subscription_list` and present the result as a numbered picklist. Wait for the user. Re-stamp `${input:subscription_id}` with the chosen UUID. Do **not** default-pick.
2. **If `${input:resource_group}` is empty or literally `""`:** call `mcp_azure_mcp_ser_group_list` with the chosen subscription. Present the result as a numbered picklist. Wait for the user. Re-stamp `${input:resource_group}`. Do **not** default-pick.
3. **If both were already populated:** echo them back to the user once for confirmation ("Auditing subscription **\<id\>** / RG **\<name\>**."), then continue.

> Empty inputs are a **verdict, not "ok"** — do not pass them to the wrapper unresolved. The wrapper will exit non-zero on the missing positional arg and force the user to re-run.

## Step 1 — Run assessment (preflight + discover + format in one call)

`assess-project.sh` is the TD-33 wrapper that collapses preflight,
discovery, and formatting into a single tool round-trip. Happy path is one
call; only the ambiguous-account/project case requires a second invocation
(after the picklist is shown to the user).

```bash
OUT_DIR="${input:out_dir:-./assessment}"

.agents/skills/foundry-deploy/scripts/assess-project.sh \
  ${input:subscription_id} \
  ${input:resource_group} \
  "${input:account_name:-}" \
  "${input:project_name:-}" \
  "$OUT_DIR" \
  > /tmp/assess-project.stdout 2> /tmp/assess-project.stderr

EXIT=$?
echo "[i] assess-project wrapper exit code: $EXIT"
```

The wrapper does, in order:

1. Best-effort caller-role preflight (`Reader` on RG — non-blocking; if the
   `assess-project` alias is unknown on older installs the wrapper logs
   "skipped" and continues, since every downstream call is `GET` and any
   `403` surfaces clearly).
2. `discover-project-topology.sh` (read-only) → `/tmp/assess-project.kv`.
3. `discover-project-topology.py` (formats KEY=VALUE stream into
   `project-topology.md` / `.json` / `agent-capabilities.draft.yaml`).
4. Emits machine-readable pointers on stdout:
   `ASSESSMENT_STATUS={ok|ambiguous}`, `ASSESSMENT_REPORT_MD=...`,
   `ASSESSMENT_REPORT_JSON=...`, `ASSESSMENT_STUB_YAML=...` (if written),
   `ASSESSMENT_KV_FILE=...`.

Possible exit codes (propagated from the discovery script):

| Code | Meaning | What to do next |
|---|---|---|
| `0` | Topology emitted (may include ⚠ verdicts) | Continue to Step 3 |
| `2` | Account exists but `allowProjectManagement != true` | Print: "Account is not Foundry-grade. Recreate with `allowProjectManagement=true` or pick another account in this RG." Tail `/tmp/assess-project.stderr`. STOP. |
| `3` | No `Microsoft.CognitiveServices/accounts` in the RG | Print: "No Foundry / AI Services account in `${input:resource_group}`. Create one via the portal or `az cognitiveservices account create --kind AIServices --custom-domain ...`." STOP. |
| `4` | **Ambiguous** — multiple Foundry-grade accounts or multiple projects, and no hint passed | **Picklist dispatch — see Step 2.** |
| other | Wrapper internal error (preflight script missing, format failure) | Tail `/tmp/assess-project.stderr` and surface. STOP. |

## Step 2 — Exit 4 picklist dispatch (only when ambiguous)

When `EXIT=4`, the wrapper has already emitted the candidate list on stdout
(also persisted at `/tmp/assess-project.kv`). Parse it to find the
candidates, then **interactively** ask the user to pick. Do NOT default-pick:

```bash
STATUS=$(grep '^TOPOLOGY_STATUS=' /tmp/assess-project.kv | cut -d= -f2)
```

- **`STATUS=ambiguous-account`** — grep all `ACCOUNT_NAME_<n>=` rows and
  pair them with their `ACCOUNT_KIND_<n>` / `ACCOUNT_ALLOW_PROJECT_MANAGEMENT_<n>`
  / `ACCOUNT_LOCATION_<n>` siblings. Present only the rows where
  `ALLOW_PROJECT_MANAGEMENT=true` as numbered Foundry-grade choices. Surface
  non-Foundry rows separately so the user can see them (e.g. ContentSafety)
  but cannot pick them. Wait for the user. Re-invoke the wrapper with the
  chosen `<account_name>` as positional arg 3.
- **`STATUS=ambiguous-project`** — grep `PROJECT_NAME_<n>=` rows and present
  them as a numbered picklist. Wait for the user. Re-invoke the wrapper with
  both the already-chosen `<account_name>` AND the chosen `<project_name>`
  (positional args 3 + 4).

**Re-invocation pattern (always include the already-resolved hint):**

```bash
.agents/skills/foundry-deploy/scripts/assess-project.sh \
  ${input:subscription_id} ${input:resource_group} \
  "$CHOSEN_ACCOUNT" "$CHOSEN_PROJECT" "$OUT_DIR" \
  > /tmp/assess-project.stdout 2> /tmp/assess-project.stderr
EXIT=$?
```

A second exit `4` after a hint means the user typo'd — re-show the picklist
with the failure surfaced from stderr.

### Why this matters — what silent picking would hide

A real RG often has 2–4 Foundry-grade accounts (e.g. region-pinned siblings:
`agents-eastus`, `agents-eastus2`, `agents-ncus-2`). Silently choosing the
first one loses context: its sibling accounts may host the actual model
deployments, knowledge connections, or even the project the user meant. The
verdict report would be technically accurate for a project the user did not
intend to audit. Exit `4` forces an explicit choice.

### What the formatter writes

The wrapper has already invoked the formatter. The output files are:

| File | Purpose |
|---|---|
| `$OUT_DIR/project-topology.md` | Human report (✅/⚠/❌ table + Top 3 + per-category detail) |
| `$OUT_DIR/project-topology.json` | Machine-readable equivalent — for CI gates and `/prepare-deploy` cross-check |
| `$OUT_DIR/agent-capabilities.draft.yaml` | Pre-filled stub with discovered target / network / knowledge stubs + `# TODO` markers |

> **Note:** `emit_stub` is no longer a wrapper input. The formatter always
> writes the stub; if you don't want it, simply delete the file after.
> Earlier versions exposed `--no-stub` directly; that mode is still
> available by invoking `discover-project-topology.py` standalone.

## Step 3 — Render the verdict inline

Read `$OUT_DIR/project-topology.md` and print it to the user verbatim (preserve the table and the "Top 3" block). Then add a one-line summary:

> Assessment complete. Account=**\<account\>** Project=**\<project\>** Connections=**N** CapHosts=**N proj/N acct** Deployments=**N** Agents=**N**. Top issue: **<headline>**.

For each ❌ or ⚠ verdict, the referenced skill path (column 4 of the table) tells the user where to read for the fix. **Do not auto-execute a fix.** This is an audit; remediation is a separate prompt run.

### Zero-deployment assist (FB-5)

If `project-topology.json` has `deployments[]` empty (`DEPLOYMENT_COUNT=0`), the project will fail every downstream `/plan-agent` model interview. Surface a copy-pasteable bootstrap block alongside the verdict (do **not** auto-run it — model deployment is a mutation):

```bash
# Pick a current Foundry-supported model + version via the helper (NEVER hand-pick from a recipe).
.agents/skills/foundry-deploy/scripts/select-model.sh \
    --subscription "${input:subscription_id}" \
    --resource-group "${input:resource_group}" \
    --account "<account_name>" \
    --project "<project_name>"

# Then create the deployment (substitute the chosen MODEL_NAME / MODEL_VERSION / DEPLOYMENT_NAME):
az cognitiveservices account deployment create \
    --resource-group "${input:resource_group}" \
    --name "<account_name>" \
    --deployment-name "<DEPLOYMENT_NAME>" \
    --model-name "<MODEL_NAME>" \
    --model-version "<MODEL_VERSION>" \
    --model-format OpenAI \
    --sku-capacity 120 \
    --sku-name GlobalStandard
```

After the user creates a deployment, re-run `/assess-project` to refresh the topology. The new deployment will appear in `project-topology.json` `deployments[]` and the verdict table will flip the row from ❌ to ✅.

## Step 4 — Offer to use the stub

If `agent-capabilities.draft.yaml` was written and the user wants to start a new agent, offer:

> Want me to start `/plan-agent` and prefill `target:` / `network:` / `knowledge:` from the discovered topology? I'll skip the corresponding interview questions and surface only fields the stub left as `TODO`.

If yes, hand off to `/plan-agent`. `/plan-agent` Step 0a auto-detects the cached `project-topology.md` and `agent-capabilities.draft.yaml` in the current working directory and reads them instead of re-asking.

## Step 5 — Offer capability-host remediation (only if the verdict flagged ⚠)

If the `Capability hosts` row in the verdict table is ⚠ (any of: no host at any scope, account host only with project host missing, project host present but BYO bindings partial), offer:

> Want me to run `/add-capability-host` to wire BYO Cosmos + AI Search + Storage to project `<project>`? I'll dry-run first so you can see the PUT bodies before any mutation.

If yes, hand off to `/add-capability-host` with `subscription_id` / `resource_group` / `account_name` / `project_name` already resolved. The `/add-capability-host` prompt re-reads `$OUT_DIR/project-topology.json` so you don't repeat the discovery, then asks which connections to bind.

Do NOT offer this remediation if the row is ✅ — the project capHost is fully wired.

## Forbidden shortcuts

- ❌ Do NOT run `discover-target.sh` instead — it is a narrower minimum-set query and will not produce the verdict table.
- ❌ Do NOT skip Step 1 and synthesize verdicts from MCP-tool output. Every verdict MUST come from the formatter so symbols are consistent across the skillpack.
- ❌ Do NOT call `discover-project-topology.sh` and `discover-project-topology.py` separately when `assess-project.sh` (the TD-33 wrapper) is available — that wastes a tool round-trip and bypasses the stderr-tailing the wrapper does on failure.
- ❌ Do NOT mutate `agent-capabilities.yaml` directly. The stub is `agent-capabilities.draft.yaml` — promoting it is a deliberate `mv` after the user reviews every `TODO`.
- ❌ Do NOT deploy a model, create a connection, or change `publicNetworkAccess` from this prompt. Route the user back to `/plan-agent` / `/prepare-deploy`.
- ❌ Do NOT call `/add-capability-host` directly without first showing the dry-run output to the user — it WILL mutate the Foundry account when run with `--no-dry-run`.
- ❌ Do NOT read `chat-session-resources/`, `content.json`, or any path under `.vscode-server/` to enumerate models / regions / subscriptions. Those are session caches and out of contract. Use MCP tools + `select-model.sh` only (FB-11).
- ❌ Do NOT default-pick the first subscription or RG when the user left them blank. Always show the MCP picklist (FB-2).

