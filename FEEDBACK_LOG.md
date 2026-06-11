# Consumer-Workspace Test Feedback Log

Running log of issues found while dogfooding the skillpack from a **fresh consumer
workspace** (separate folder, `apm install` from GitHub, then run the prompts).
Each entry: what the user did → what happened → what should happen → fix owner.

> Source of truth for fixes is `foundry-agent-skillpack/.apm/`. Mirror to
> `.agents/` + `.github/prompts/` happens on `apm install` in the test workspace.

> **Round 1 closeout (v0.27.0).** All 21 entries below (FB-1 … FB-21) were
> addressed in a single batch release — see the v0.27.0 changelog in
> `foundry-agent-skillpack/apm.yml`. Status lines below are marked
> "closed in v0.27.0"; the actual commit sha is recorded in git history.
> Round 2 testing should begin **after** v0.27.0 is published.

---

## Verified install sequence (Copilot / VS Code)

Two `apm install` calls are required — the playbook **does not** auto-install
the skillpack. Run both, in this order, with `--target copilot`:

```bash
mkdir -p ~/work/foundry-agent-test && cd ~/work/foundry-agent-test

apm install sathik11/foundry-agent-skillpack/foundry-agent-skillpack --target copilot
apm install sathik11/foundry-agent-skillpack/foundry-agent-playbook  --target copilot
```

Verify both landed:

```bash
ls .github/prompts/                          # 11 *.prompt.md (assess-project, plan-agent, …)
ls .agents/skills/                           # foundry-deploy, foundry-evals, foundry-knowledge, …
ls .agents/skills/foundry-agent-playbook/    # recipes/ + fixtures/  (proves playbook landed too)
```

**Wrong forms that fail (do not use):**

| Bad form | Error |
|---|---|
| `apm install github:sathik11/foundry-agent-skillpack/foundry-agent-playbook` | `Invalid repository path component: github:sathik11` |
| `apm install sathik11/foundry-agent-playbook` | repo path missing the subdir |

---

## Feedback items

### FB-1 — Install docs only show one `apm install`, but BOTH packages are required

**Date:** 2026-06-09
**Reporter:** sathik
**Severity:** docs (high — first-run friction)

**What the user saw.** Followed the README "Install" snippet which shows the two
commands stacked but reads as alternatives. Also, an earlier chat reply
suggested `apm install sathik11/foundry-agent-skillpack/foundry-agent-playbook
--target copilot` as a single command. Without the skillpack call first, the
playbook install resolves but the skills directory ends up missing the
`foundry-deploy` / `foundry-evals` / `foundry-roles` skills the playbook
recipes reference.

**What should happen.** Both `README.md` and
`docs/src/content/docs/getting-started/install.md` need an explicit
"**run both, in this order**" callout. Chat replies that suggest installing
only one of the two should be considered a bug.

**Owner / fix.** Update `README.md` + `docs/src/content/docs/getting-started/install.md`
to mark the pair as required, not optional. Add a verification snippet
(`ls .agents/skills/` showing both `foundry-*` and `foundry-agent-playbook`).

**Status:** closed in v0.27.0.

---

### FB-2 — `/assess-project` has no Step 0 subscription/RG discovery — first-time users can't fill in inputs

**Date:** 2026-06-09
**Reporter:** sathik
**Severity:** prompt UX (high — blocks every first invocation)

**What the user saw.** Invoked `/assess-project` from a fresh workspace.
The prompt's `input:` block declares `subscription_id` and `resource_group`
as **required**, but the prompt body jumps straight to Step 1 (`run
assessment`). There is no Step 0 that helps the user pick the subscription
or RG when they don't already have those values memorized.

By contrast, `/plan-agent` Step 0a explicitly does:
> "If the user did not pass `subscription=`, list subscriptions with
> `mcp_azure_mcp_subscription_list` and show a numbered picklist. Wait for
> the user's selection. Never auto-pick."

`/assess-project` should do the same — it is even more likely to be the
**first** prompt a user runs (because it's read-only and the entry point
into the lifecycle).

**What should happen.** Add a Step 0 to
`foundry-agent-skillpack/.apm/prompts/assess-project.prompt.md` that:

1. If `subscription_id` is empty → call `mcp_azure_mcp_subscription_list`,
   show numbered picklist, wait for user.
2. If `resource_group` is empty → call
   `mcp_azure_mcp_group_list --subscription <id>`, show numbered picklist
   filtered to RGs containing `Microsoft.CognitiveServices/accounts` if
   possible (otherwise show all). Wait for user.
3. Only then proceed to Step 1 (`assess-project.sh ...`).

Same anti-synthesis guard as `/plan-agent`: **never auto-pick**, never
echo example values.

**Owner / fix.** Edit
[foundry-agent-skillpack/.apm/prompts/assess-project.prompt.md](foundry-agent-skillpack/.apm/prompts/assess-project.prompt.md),
renumber existing Step 1/2/3 → Step 2/3/4, mirror to
`.github/prompts/assess-project.prompt.md`, drift check, smoke `apm install
--target copilot`.

**Status:** closed in v0.27.0.

---

### FB-3 — `/assess-project` should require account + project, not pass empty strings through

**Date:** 2026-06-09
**Reporter:** sathik
**Severity:** prompt UX (high — produces a misleading "ok" with no scoping)

**What the user saw.** In the test workspace, the prompt invoked the wrapper
with `""` `""` for account and project:

```bash
.agents/skills/foundry-deploy/scripts/assess-project.sh \
  d194e976-63c4-43c9-995a-5340d0daffb1 \
  agents-3iq \
  "" \
  "" \
  "./assessment" \
  > /tmp/assess-project.stdout 2> /tmp/assess-project.stderr
```

The current prompt body marks `account_name` / `project_name` as optional and
only solicits them via the **exit-4 picklist** path (when the RG has multiple
candidates). For an RG with a single Foundry account + single project the
script silently auto-picks — but the user has no idea which account/project
was actually assessed without reading the generated report.

**What should happen.** Same Step 0 added in FB-2 should also enumerate
Foundry accounts in the chosen RG and projects in the chosen account, and
**always** make the user pick (or confirm the single match) before the
script runs. Drop the `""` empty-arg form from the documented invocation —
always pass concrete `account_name` and `project_name`.

Equally: the prompt should print, after the wrapper runs, a one-line
confirmation `[i] assessed: <account> / <project>` echoing the values that
were used, so the user can sanity-check before reading the report.

**Owner / fix.** Same file as FB-2
([assess-project.prompt.md](foundry-agent-skillpack/.apm/prompts/assess-project.prompt.md)).
The Step 0 added for FB-2 should cover both subscription/RG **and**
account/project discovery. Keep the wrapper's exit-4 path as a fallback for
agents that bypass the prompt and call the script directly.

**Status:** closed in v0.27.0.

---

### FB-4 — Verbose bash ceremony shown to the user instead of silent execution

**Date:** 2026-06-09
**Reporter:** sathik
**Severity:** prompt UX (medium — noise, not a blocker)

**What the user saw.** When the agent runs `assess-project.sh` from the
`/assess-project` prompt, it dumps the full bash plumbing into chat:

```bash
cd /home/sathik/work/code/foundry/foundry-skillpack-test && \
.agents/skills/foundry-deploy/scripts/assess-project.sh \
  d194e976-63c4-43c9-995a-5340d0daffb1 \
  agents-3iq \
  "" \
  "" \
  "./assessment" \
  > /tmp/assess-project.stdout 2> /tmp/assess-project.stderr

EXIT=$?
echo "[i] assess-project wrapper exit code: $EXIT"
cat /tmp/assess-project.stdout
```

That's an implementation detail leaking into the user surface. Other
lifecycle prompts (e.g. `/configure-rbac`, `/verify-agent`) just call the
script and report the parsed result — they don't show the `> /tmp/...`
redirection or the `cat` of the buffered output.

**What should happen.** The `/assess-project` prompt body should follow the
same pattern: run the wrapper, capture its KEY=VALUE stdout, parse the
machine-readable pointers (`ASSESSMENT_STATUS=`,
`ASSESSMENT_REPORT_MD=`…), and report the human-grade summary back.
The user should never see the `> /tmp/...` plumbing.

Open question (please confirm): "silent" means **don't show the bash
plumbing**, right? Not "skip the verdict summary"? The verdict + ⚠/✅
inline summary is still wanted — just the redirection ceremony should go.

**Owner / fix.** Edit Step 1 of
[assess-project.prompt.md](foundry-agent-skillpack/.apm/prompts/assess-project.prompt.md)
to drop the explicit `> /tmp/assess-project.stdout 2>
/tmp/assess-project.stderr` block and instead instruct the agent to invoke
the wrapper directly and parse its stdout. Will be folded into the same
fix commit as FB-2 / FB-3.

**Status:** closed in v0.27.0.

---

### FB-5 — Should the skillpack assist with model deployments when discovery flags `⚠ Zero deployments`?

**Date:** 2026-06-09
**Reporter:** sathik
**Severity:** prompt UX (low — feature request, not a blocker)

**What the user saw.** `/assess-project` correctly surfaces
`⚠ Model deployments: Zero deployments on chosen project's account` and the
remediation guidance today is "go run `az cognitiveservices account
deployment create ...` yourself, then re-run `/assess-project`." This is a
manual hop the user has to do outside the lifecycle.

**What should happen.** Either:

- **Option A (cheap):** Have `/assess-project` emit a copy-pasteable
  `az cognitiveservices account deployment create` block scoped to the
  chosen account, with a sensible default (`gpt-4o-mini`, GlobalStandard,
  50 TPM) so the user can run it without leaving chat. Still manual but
  zero friction.
- **Option B (deeper):** Introduce a small `/deploy-model` prompt (or fold
  into `/plan-agent` Step 0) that:
  1. Lists the model catalog filtered to the chosen account's region (via
     `mcp_microsoft_mac_model_catalog_list` if available, otherwise
     `az cognitiveservices model list`),
  2. Asks the user to pick a model + SKU + capacity,
  3. Issues the deployment + polls to `Succeeded`,
  4. Re-runs `/assess-project` to refresh the topology.

Pick A first (1-day change), revisit B after the rest of Round 1 lands.

**Owner / fix.** Edit Step 3 of
[assess-project.prompt.md](foundry-agent-skillpack/.apm/prompts/assess-project.prompt.md)
(or Step 0 of [plan-agent.prompt.md](foundry-agent-skillpack/.apm/prompts/plan-agent.prompt.md))
to emit the copy-pasteable `az` block for Option A. Option B would be a
new `foundry-agent-skillpack/.apm/prompts/deploy-model.prompt.md`.

**Status:** closed in v0.27.0.

---

### FB-6 — Discovery should also inspect the linked ACR (catalog of hosted-agent images)

**Date:** 2026-06-09
**Reporter:** sathik
**Severity:** discovery completeness (medium — affects brownfield + redeploy flows)

**What the user saw.** `discover-project-topology.sh` enumerates the
Foundry account, project, connections, capability hosts, network class,
model deployments, and agents — but it does **not** inspect the **linked
Azure Container Registry**. For hosted-agent deployments (`azd up` builds
an image, pushes to ACR, and the Foundry control plane pulls from there),
the ACR is part of the project's effective topology.

Why this matters:

- **Brownfield onboarding.** When joining a team mid-project, knowing
  "there are already 3 agent images in ACR (`learn-agent:v2`,
  `intake-agent:v1`, `narrative-agent:v4`)" is part of the topology
  briefing.
- **Redeploy hygiene.** Confirms the ACR is reachable from the project's
  network class (managed VNet / BYO VNet / public). An unreachable ACR is
  a silent gap that only surfaces at `azd up` time.
- **Capacity planning.** Image count + tag history feeds the per-agent
  cost discussion that `foundry-prod-readiness` skill already documents.

**What should happen.** Extend `discover-project-topology.sh` to:

1. Resolve the linked ACR from the project's `azureContainerRegistry`
   connection (if present) — fall back to any `Microsoft.ContainerRegistry/registries`
   in the same RG as a heuristic.
2. Enumerate repositories + most recent tag per repo via
   `az acr repository list` + `az acr repository show-manifests --top 1`.
3. Emit KV stream: `ACR_NAME=`, `ACR_LOGIN_SERVER=`, `ACR_PUBLIC_ACCESS=`,
   `ACR_REPO_COUNT=`, `ACR_REPOS=<repo1:tag1,repo2:tag2,...>`.
4. Add a verdict row in `project-topology.md`:
   - ✅ ACR linked + reachable + ≥1 repo,
   - ⚠ ACR linked but empty or public-access toggle disagrees with
     network class,
   - ❌ no ACR connection found.

Also surface it in `agent-capabilities.draft.yaml` so `/plan-agent` Step
0a can pre-populate the deploy target.

**Owner / fix.** Edit
[foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-project-topology.sh](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/discover-project-topology.sh)
+ `discover-project-topology.py` (verdict logic + report renderer) +
`project-topology.md` skill doc (document the new section). Add to the
verdict rubric in
[assess-project.prompt.md](foundry-agent-skillpack/.apm/prompts/assess-project.prompt.md).

**Status:** closed in v0.27.0.

---

### FB-7 — `/plan-agent` (or whichever prompt scaffolded `hello-agent`) emitted an unnecessary `cp guardrails.py` step

**Date:** 2026-06-09
**Reporter:** sathik
**Severity:** prompt UX (medium — clutters the agent folder, confuses future maintainers)

**What the user saw.** Mid-scaffold, the prompt asked the user to run:

```bash
cp /home/sathik/work/code/foundry/foundry-skillpack-test/.agents/skills/foundry-guardrails/scripts/guardrails.py \
   /home/sathik/work/code/foundry/foundry-skillpack-test/agents/hello-agent/guardrails.py
```

Two problems:

1. **The copy is unnecessary.** `guardrails.py` already lives at
   `.agents/skills/foundry-guardrails/scripts/guardrails.py` and is imported
   at runtime from there — the agent container build path doesn't require
   a local copy in `agents/hello-agent/`. Whatever prompt emitted this is
   confusing "vendored at runtime" with "vendored into the agent source
   tree."
2. **It pollutes the agent folder** with a duplicate that will drift from
   the skill version on the next `apm install`, breaking the
   `/audit-drift` baseline.

**What should happen.** Identify which prompt emitted the `cp` (likely
`/plan-agent` when `guardrails: { mode: middleware }` is declared in the
draft manifest, OR `/prepare-deploy` during the audit) and remove the
copy step. The agent's Dockerfile / entry point should import from
`.agents/skills/foundry-guardrails/scripts/guardrails.py` directly (or
the skill's `__init__.py` if Python packaging is involved).

**Open question for the user (please answer):** can you paste the exact
chat turn where this `cp` instruction appeared? I need to know which
prompt emitted it (`/plan-agent` vs `/prepare-deploy`) before I can route
the fix to the right file.

**Owner / fix.** TBD — depends on which prompt emitted it. Candidates:
- [plan-agent.prompt.md](foundry-agent-skillpack/.apm/prompts/plan-agent.prompt.md)
- [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md)
- A skill snippet under [.apm/skills/foundry-guardrails/](foundry-agent-skillpack/.apm/skills/foundry-guardrails/)

**Status:** closed in v0.27.0.

---

### FB-8 — `azd` + `azure.ai.agents` extension preflight shown as raw bash with leaking plumbing

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (medium — same flavor as FB-4)

**What the user saw.** During the `/plan-agent` flow (or — see open question
below — possibly during the `/prepare-deploy` handoff that `/plan-agent`
triggers at the end), the chat surface showed this multi-line bash block
verbatim, comments and all:

```bash
cd /home/sathik/work/code/foundry/foundry-skillpack-test && \
# azd CLI must be installed.
azd version 2>&1 || { echo "ERROR: azd CLI not on PATH"; exit 1; }

echo "---"

# azure.ai.agents extension must be installed.
ext_line=$(azd ext list 2>/dev/null | grep -E '^[[:space:]]*azure\.ai\.agents\b') \
  || { echo "ERROR: azd ai agent extension not installed — run: azd ext install azure.ai.agents"; exit 1; }
```

Two issues:

1. **Same plumbing-leak as FB-4.** The user shouldn't see the raw inline
   bash, the `&&` continuations, the `2>&1`, the `echo "---"` separator,
   or the `>/dev/null 2>&1`. The prompt should run the preflight silently
   and report `[+] azd <version> + azure.ai.agents <version> OK` (or the
   parsed error + recovery command), not paste the script into chat.
2. **Version alignment is brittle.** The block hard-codes
   `required="0.1.27"` ("first build on the refreshed hosted-agents
   backend") in
   [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md).
   That floor will drift — every time the `azd ai agent` extension ships
   a backend-breaking release, the prompt has to be re-edited. User
   reports the impression that "azd version must be aligned" — the floor
   should probably move to a versioned constant in the
   `foundry-deploy` skill (e.g. `MIN_AZD_AI_AGENTS_VERSION` in a skill
   metadata file) so it's updated in one place and not re-prompted at
   every preflight.

Also: the comment `# Minimum version 0.1.27 (the first build on the
refreshed hosted-agents backend).` is a fact that should live in the
failure-modes skill, not inline in the preflight, so the runbook on
failure can hyperlink to the explanation.

**What should happen.**

- **Short term:** wrap the preflight into a script
  `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/preflight-azd.sh`
  that emits KV stdout (`AZD_OK={ok|missing|too_old}`,
  `AZD_VERSION=...`, `EXT_VERSION=...`, `RECOVERY_CMD=...`). The
  `/prepare-deploy` prompt then just invokes it and reports the
  one-liner result.
- **Medium term:** move the `0.1.27-preview` floor to a constant in
  [foundry-agent-skillpack/.apm/skills/foundry-deploy/](foundry-agent-skillpack/.apm/skills/foundry-deploy/)
  (e.g. a `versions.yaml` or `MIN_AZD_AI_AGENTS_VERSION` env-var sourced
  by the script). One place to bump on each backend change.
- **Critical constraint from user (2026-06-10):** "the azd cannot be
  locked — whenever we update we must also look at this critical
  dependency." Two implications:
  1. The minimum-version floor cannot silently auto-pin without explicit
     maintainer review on every bump. The floor must live in a single
     `versions.yaml` (or equivalent) that is **part of the maintainer's
     review checklist** — not a value the prompt reads + forgets.
  2. On every skillpack release, the `azd ai agent` extension changelog
     must be diffed against the current floor. Add this to
     `TECHNICAL_DEBT.md` as a recurring maintenance task / release gate.

**User clarification (2026-06-10):** confirmed the block surfaced from
`/prepare-deploy`, not `/plan-agent`. No duplicated check to strip. Single
file to refactor: [prepare-deploy.prompt.md Step 0.3](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md).

**Owner / fix.** 
- New script: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/preflight-azd.sh` (silent KV emitter, reads min version from a versions file).
- New file: `foundry-agent-skillpack/.apm/skills/foundry-deploy/versions.yaml` (single source of truth: `min_azd_ai_agents_version: 0.1.27-preview`).
- Edit [prepare-deploy.prompt.md Step 0.3](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md) to call the script and report a one-liner instead of inlining bash.
- Append a release-gate item to [foundry-agent-skillpack/TECHNICAL_DEBT.md](foundry-agent-skillpack/TECHNICAL_DEBT.md): "Diff azd ai agent extension changelog against `versions.yaml` on every skillpack release."

**Status:** closed in v0.27.0.

---

### FB-9 — H6/H7/H8/H9 verification checks emit raw multi-line bash with `echo "==="` headers

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (medium — same plumbing-leak family as FB-4 / FB-8)

**What the user saw.** During `/prepare-deploy`, the chat surface showed
the Tier-H verification checks (H6 = Dockerfile, H7 = zip layout, H8 =
dependency strategy, H9 = Python version) as one giant inline bash block
with `echo "=== H6: Dockerfile check ==="` separators, `if [ -f ... ];
then ... fi` constructs, and a literal `ls -la` dump:

```bash
cd /home/sathik/work/code/foundry/foundry-skillpack-test/agents/hello-agent && \
echo "=== H6: Dockerfile check ===" && \
if [ -f Dockerfile ]; then echo "❌ Dockerfile present — mutually exclusive with deploy_mode: code"; else echo "✅ No Dockerfile (correct for code-deploy)"; fi && \
echo "" && \
echo "=== H7: Zip layout (pre-zip check — flat structure) ===" && \
echo "Files at agent root:" && \
ls -la && \
echo "" && \
echo "=== H9: Python version compat ===" && \
if [ -f .python-version ]; then echo "Found .python-version:"; cat .python-version; else echo "✅ No .python-version file (compatible with code.runtime python_3_13)"; fi && \
echo "" && \
echo "=== H8: Dependency strategy (remote_build) ===" && \
if [ -f requirements.txt ]; then echo "✅ requirements.txt present at root"; else echo "❌ requirements.txt missing"; fi && \
if [ -d packages ]; then echo "❌ packages/ directory present — should not exist for remote_build"; else echo "✅ No packages/ directory (correct for remote_build)"; fi
```

This is doing real work (file-presence checks for the H-Code verification
tiers documented in [foundry-deploy/code-deploy.md](foundry-agent-skillpack/.apm/skills/foundry-deploy/code-deploy.md))
but presenting it as if the user needs to read the bash to understand the
result. The user should see only:

```
[+] H6 Dockerfile absent ✅
[+] H7 Zip layout flat ✅ (4 files at root)
[+] H8 Dependency strategy remote_build ✅ (requirements.txt at root, no packages/)
[+] H9 Python version compat ✅ (no .python-version pin)
```

**What should happen.** Wrap these H-Code checks into a script
`foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/verify-code-deploy-layout.sh`
that takes `--agent-path` and emits KV stdout:

```
H6_DOCKERFILE_STATUS=absent
H7_ZIP_LAYOUT_STATUS=flat
H7_ROOT_FILE_COUNT=4
H8_DEPS_STATUS=ok
H8_REQUIREMENTS_AT_ROOT=true
H8_PACKAGES_DIR_PRESENT=false
H9_PYTHON_PIN_STATUS=none
VERIFY_LAYOUT_OK=true
```

…then the prompt reports the one-liner summary above. Same pattern
already used by `assess-project.sh` (KV emitter + prompt parses).

**Owner / fix.**
- New script: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/verify-code-deploy-layout.sh`.
- Edit the H-Code verification step in [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md) to invoke the script and report parsed results.
- Cross-reference: same fix pattern as FB-4 and FB-8; consider whether all three should share a common KV-parser helper.

**Status:** closed in v0.27.0.

---

### FB-10 — `azd ai agent init --help` discovery probes leak raw `grep | head` commands to the user

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (low-medium — same plumbing family, smaller blast radius)

**What the user saw.** During `/prepare-deploy` (in the same flow as
FB-9), the chat surface ran these two `azd ai agent init --help` probes
inline:

```bash
azd ai agent init --help 2>&1 | grep -i "deploy-mode\|deploy_mode\|code" | head -5
azd ai agent init --help 2>&1 | head -40
```

This looks like the prompt is **at runtime** trying to discover whether
the installed `azd ai agent` extension supports `--deploy-mode code` (the
code-deploy preview track from TD-31). Two problems:

1. **The plumbing leaks** — same family as FB-4 / FB-8 / FB-9. User
   shouldn't see `2>&1 | grep -i ... | head -5`.
2. **It's redundant with the version preflight (FB-8).** If the
   `azure.ai.agents` extension version preflight already enforces
   `>= 0.1.27-preview` (the floor where `--deploy-mode code` lands per
   [prepare-deploy.prompt.md L150](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md#L150)),
   then probing `--help` at runtime to detect the flag is belt-and-braces.
   Either the version preflight is authoritative (in which case drop
   the `--help` grep entirely) or the version preflight is not
   trustworthy (in which case fix the preflight, not the redundant probe).

**What should happen.** Pick one path:

- **Path A (preferred, cheap):** Delete the `--help` probes entirely.
  Trust the FB-8 version preflight. If the user passed it, the flag
  exists.
- **Path B (defense-in-depth):** Keep a single capability probe but
  silence it — fold it into the `preflight-azd.sh` script proposed in
  FB-8 and emit `AZD_CODE_DEPLOY_FLAG_PRESENT={true|false}`. Surface
  only the human-grade verdict.

Recommend Path A — `versions.yaml` plus the version preflight is
sufficient; the `--help` grep is the kind of "just in case" code that
rots quietest when the extension's help text format changes (e.g. "code"
appearing in any other flag's docstring would false-positive the grep).

**Owner / fix.** Grep [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md)
for `azd ai agent init --help` and remove the probe block. Verify the
downstream `azd ai agent init --deploy-mode code ...` invocation still
has a single trapped error path that prints the recovery command on
failure (so a missing flag still produces a clean error, just via the
actual call's exit code rather than a pre-probe).

**Status:** closed in v0.27.0.

---

### FB-11 — Model-deployment discovery hand-rolled in a Python heredoc that reads a VS Code internal chat-cache file, instead of calling the existing `select-model.sh`

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** **high — correctness + portability + security smell**, not just plumbing

**What the user saw.** During `/prepare-deploy` (or `/plan-agent` Step 0
model-pick — TBD; see open question), the chat surface ran:

```bash
cat /home/sathik/.vscode-server/data/User/workspaceStorage/1e05e753be960c482449af495f27109f/GitHub.copilot-chat/chat-session-resources/bfda50b9-0cba-4cb2-b657-bc84619d76c3/toolu_01YS5dp9CdpabCrU1xrYYc1a__vscode-1780982004006/content.json | python3 -c "
import json, sys
data = json.load(sys.stdin)
for item in data:
    d = item.get('data', {})
    name = d.get('name', item.get('id',{}).get('name','?'))
    model = d.get('properties',{}).get('model',{})
    caps = d.get('properties',{}).get('capabilities',{})
    agents = caps.get('agentsV2', 'false')
    responses = caps.get('responses', 'false')
    print(f'{name:30s} model={model.get(\"name\",\"?\"):20s} v={model.get(\"version\",\"?\"):15s} agents={agents} responses={responses}')
"
```

Three distinct problems, in escalating severity:

1. **Plumbing leak (same family as FB-4 / FB-8 / FB-9 / FB-10).** User
   sees raw inline Python heredoc with f-string escaping. Should be a
   one-liner script call with parsed result.
2. **Reads a VS Code internal cache path** —
   `~/.vscode-server/data/User/workspaceStorage/<workspaceHash>/GitHub.copilot-chat/chat-session-resources/<sessionId>/<toolCallId>/content.json`.
   This is **the agent's own tool-call result cache**, not a public API.
   Three things wrong with that:
   - **Brittle.** Path format is undocumented and tied to the
     GitHub.copilot-chat extension's internal storage. Any extension
     bump can move it. The hard-coded workspace hash + session id + tool
     call id will *never* match on a different machine, a different
     workspace, or even the next chat session in the same workspace.
   - **Unportable.** Will 100% fail on any user who isn't `sathik` on
     this exact Linux VS Code Server install with this exact session
     state.
   - **Security smell.** Encourages a pattern of "reach into the chat
     client's private files to re-parse tool output." If a future
     Copilot release encrypts or relocates these files, the prompt
     silently breaks; worse, if a malicious tool gets the agent to
     `cat` arbitrary files under that tree, it can exfiltrate prior
     tool results.
3. **Reinvents an existing, tested script.** [`select-model.sh`](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/select-model.sh)
   already does **exactly** the same job, properly, via `az
   cognitiveservices account deployment list` — it parses
   `properties.capabilities.agentsV2`, supports a deployment hint,
   auto-picks a single deployment, falls back to the first
   agents-capable one, and emits KV stdout
   (`MODEL_DEPLOYMENT_NAME=...`, `MODEL_AGENTS_CAPABLE=...`,
   `MODEL_SELECTION_METHOD=...`). The Python heredoc is doing a strict
   subset of that work, badly.

**What should happen.** Whatever prompt emitted the Python heredoc must
be edited to call `select-model.sh` instead. Concretely:

```bash
.agents/skills/foundry-deploy/scripts/select-model.sh "$SUB" "$RG" "$ACCOUNT"
# parse KV stdout → MODEL_DEPLOYMENT_NAME, MODEL_AGENTS_CAPABLE, etc.
```

Then the prompt reports the one-liner:

```
[+] Model: gpt-4o-mini (gpt-4o-mini 2024-07-18) — agentsV2 ✅ — auto-selected (single deployment)
```

The VS Code chat-cache `cat` must **never** appear in any prompt or
skill script. If a prompt needs to re-read a prior tool result, the right
fix is to re-invoke the tool, not to grovel through the client's storage.

**Open question for the user (please answer):** which prompt emitted
the Python heredoc — `/plan-agent` (model selection during scaffolding)
or `/prepare-deploy` (model presence check during preflight)? Knowing
this routes the fix.

**Owner / fix.**
- Grep [foundry-agent-skillpack/.apm/prompts/](foundry-agent-skillpack/.apm/prompts/)
  for `chat-session-resources` or `agentsV2.*python3 -c` or
  `content.json` to find the offending block. (None should exist; if
  found, it's the offending prompt.)
- If grep returns empty, the agent likely **synthesized** this from
  scratch (which is also a fixable problem — strengthen the
  anti-synthesis guard in the relevant prompt to forbid reading
  `chat-session-resources/`).
- Replace with a call to [`select-model.sh`](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/select-model.sh).
- Add a hard rule to a top-level skill (e.g. `foundry-deploy/SKILL.md`):
  "Prompts and scripts MUST NOT read from
  `~/.vscode-server/data/User/.../chat-session-resources/`.
  This path is VS Code's private chat-client storage. To re-use a
  prior tool result, re-invoke the tool."

**Status:** closed in v0.27.0.
prompt); the "never read chat-session-resources" rule can land
unblocked.

---

### FB-12 — `/prepare-deploy` opens the cached `project-topology.json` via three separate inline Python heredocs instead of one structured read

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (high — same plumbing family + cardinality)

**What the user saw.** During `/prepare-deploy` Step 0 (topology
cross-check from the cached assessment), the chat surface ran **three
separate Python heredocs** in sequence, each its own approval prompt:

```bash
# heredoc 1: existence + summary
if [ -f ./assessment/project-topology.json ]; then
  echo "✅ Cached topology found"
  python3 -c "
import json
with open('./assessment/project-topology.json') as f:
    topo = json.load(f)
print('Network class:', topo.get('network',{}).get('class','?'))
print('Connections:', [c.get('category','?') for c in topo.get('connections',[])])
print('CapHost count:', len(topo.get('capability_hosts',[])))
"
else echo "No cached topology"; fi
```

```python
# heredoc 2: top-level structure introspection
import json
with open('./assessment/project-topology.json') as f: topo = json.load(f)
print(json.dumps(list(topo.keys()), indent=2))
for k,v in topo.items():
    if isinstance(v, dict):  print(f'{k}: {list(v.keys())}')
    elif isinstance(v, list): print(f'{k}: [{len(v)} items]')
    else:                     print(f'{k}: {v}')
```

```python
# heredoc 3: drill into 'raw' KV stream
import json
with open('./assessment/project-topology.json') as f: topo = json.load(f)
raw = topo['raw']
print('NETWORK_CLASS:', raw.get('NETWORK_CLASS'))
print('CONNECTION_CATEGORIES:', raw.get('CONNECTION_CATEGORIES'))
print('DEPLOYMENT_OWN_ACCOUNT_COUNT:', raw.get('DEPLOYMENT_OWN_ACCOUNT_COUNT'))
print('CAPHOST_PROJECT_COUNT:', raw.get('CAPHOST_PROJECT_COUNT'))
```

Four distinct problems:

1. **Three approvals instead of one.** Each heredoc is its own
   permission prompt to run python. User explicitly called this out: *"so
   many approvals."*
2. **The agent is reverse-engineering the JSON schema at runtime.**
   Heredoc 2 (`print(json.dumps(list(topo.keys())))` + structural
   walk) exists only because the prompt doesn't know the schema. If the
   prompt knew where to look, heredocs 1 and 2 collapse into "open the
   file at known path X and read keys Y, Z."
3. **Same plumbing leak family as FB-4 / FB-8 / FB-9 / FB-10 / FB-11.**
   Raw Python heredocs with f-strings + JSON parsing should be wrapped.
4. **The cached topology already has a generated `.md` companion**
   (`project-topology.md` from FB-2/FB-3) which carries the same facts
   in a human-grade verdict format. The Python parsing of `.json` looks
   like belt-and-braces for facts already in the `.md`. If `.md` is
   authoritative for the human report and `.json` is authoritative for
   automated checks, the prompt should pick one path, not both.

**What should happen.** Add a single helper script:

```
foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/read-topology.sh
```

that takes `--field network.class`, `--field connections`, `--field
caphost_project_count`, `--all`, etc. and emits KV stdout from
`./assessment/project-topology.json`. Document the schema of
`project-topology.json` in
[foundry-agent-skillpack/.apm/skills/foundry-deploy/project-topology.md](foundry-agent-skillpack/.apm/skills/foundry-deploy/project-topology.md)
so prompts never need to introspect `topo.keys()` at runtime.

Then `/prepare-deploy` Step 0 collapses to **one** call:

```bash
.agents/skills/foundry-deploy/scripts/read-topology.sh --all
```

…and the prompt reports:

```
[+] Cached topology (./assessment): network=public, 5 connections (CognitiveServices, AIServices, AzureBlobStorage, AzureSearch, AzureMonitor), capability_hosts=1
```

**Owner / fix.**
- New script: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/read-topology.sh`.
- Document JSON schema in [project-topology.md](foundry-agent-skillpack/.apm/skills/foundry-deploy/project-topology.md).
- Edit [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md) Step 0 (topology cross-check) to call the script once instead of three heredocs.
- Same KV-parser helper pattern as FB-9 / FB-10.

**Status:** closed in v0.27.0.

---

### FB-13 — MCP reachability probe (`curl learn.microsoft.com/api/mcp`) leaked as raw `curl -s -o /dev/null -w "%{http_code}"`

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (medium — plumbing family)

**What the user saw.** During `/prepare-deploy`, the chat ran:

```bash
curl -s -o /dev/null -w "%{http_code}" --max-time 10 https://learn.microsoft.com/api/mcp 2>&1
echo
```

This is the Tier-T (Toolbox) verification — confirming the declared MCP
URL is reachable before `azd up` so a 404/timeout doesn't bite at deploy
time. The intent is right; the surface is wrong:

1. **Plumbing leak.** `-s -o /dev/null -w "%{http_code}" 2>&1` is
   server-side curl voodoo the user shouldn't see.
2. **Hard-coded MCP URL.** `https://learn.microsoft.com/api/mcp` is
   specific to the user's `learn-agent`-style declaration; for a
   different agent's MCP server the URL must come from the agent
   manifest (`tools[].mcp.endpoint` or similar). The prompt should read
   the URL from `agent.yaml` / `agent-capabilities.yaml`, not hard-code
   it.
3. **No retry, no DNS / TLS error path.** A bare `curl` returning `000`
   (DNS fail) vs `405` (server responded but rejected method) vs `200`
   (reachable) all look like single integers; the prompt should
   classify and report human-grade.

**What should happen.** Add
`foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/probe-mcp-endpoint.sh`
that takes `--manifest agent.yaml` (or a positional URL), runs `curl
--max-time 10` per declared MCP source, and emits KV:

```
MCP_PROBE_COUNT=2
MCP_PROBE_0_URL=https://learn.microsoft.com/api/mcp
MCP_PROBE_0_STATUS=405
MCP_PROBE_0_VERDICT=reachable
MCP_PROBE_1_URL=https://api.example.com/mcp
MCP_PROBE_1_STATUS=000
MCP_PROBE_1_VERDICT=dns_fail
```

`reachable` covers 2xx, 3xx, 401, 403, 405 (server responded). `dns_fail`,
`tls_fail`, `timeout`, `5xx` are distinguished. Prompt reports:

```
[+] MCP endpoints: 2 declared, 2 reachable
```

…or surfaces the failing ones with the recovery command.

**Owner / fix.**
- New script: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/probe-mcp-endpoint.sh`.
- Edit Tier-T section of [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md) to call the script (reading the URL from the manifest) instead of inlining `curl`.
- Verify that `verify-agent.prompt.md` doesn't duplicate the same `curl` inline.

**Status:** closed in v0.27.0.

---

### FB-14 — Too many separate `agent_status.py` invocations during `/prepare-deploy` → too many approval prompts

**Date:** 2026-06-10
**Reporter:** sathik (explicit: *"so many approvals"*)
**Severity:** prompt UX (high — friction kills the lifecycle's "single happy path" story)

**What the user saw.** During `/prepare-deploy`, `agent_status.py` was
invoked **at least three separate times**, each its own approval:

```bash
# call 1: init
python3 .agents/skills/foundry-deploy/scripts/agent_status.py init \
  --agent-path agents/hello-agent \
  --agent-name hello-agent \
  --agent-kind hosted
```

```bash
# call 2: update preflight section
python3 .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path agents/hello-agent \
  --section preflight \
  --json '{"capabilities": {"toolbox": {"verdict":"pass","detail":"ms-learn MCP URL reachable (405)"}, "teams": {"verdict":"warn","detail":"bot_app_id=TODO, teams_mcp_connection_id=TODO — /configure-rbac will resolve"}, "guardrails": {"verdict":"pass","detail":"middleware mode=entry, guardrails.py vendored"}, "eval": {"verdict":"pass","detail":"role=orchestrator declared"}}, "topology_crosscheck": "matched", "checked_at":"2026-06-09T23:55:00Z"}'
```

```bash
# call 3 + 4: update network section, then drift check
python3 .agents/skills/foundry-deploy/scripts/agent_status.py update \
  --agent-path agents/hello-agent \
  --section network \
  --json '{"class":"public","region":"eastus"}' && \
python3 .agents/skills/foundry-deploy/scripts/agent_status.py drift \
  --agent-path agents/hello-agent
```

That's `init` + two `update`s + `drift` = **4 separate approval
prompts** for a single conceptual operation: "stamp the preflight result
and re-baseline drift." User is right to flag this — at this cardinality
the slash-command becomes "approve, approve, approve, approve, …" and
the operator loses the thread.

**What should happen.** Two complementary fixes:

1. **Composite subcommand.** Add a single `agent_status.py
   stamp-preflight` subcommand that takes `--agent-path` +
   `--preflight-json` + `--network-json` (or reads from
   `agent-capabilities.yaml`), runs `init`-if-missing → two updates →
   drift in one process. One call, one approval, one KV result.
2. **Or: a `/prepare-deploy` wrapper script** under
   `foundry-deploy/scripts/` (e.g. `prepare-deploy.sh`) that
   orchestrates the whole sequence — preflight checks (FB-9), MCP probe
   (FB-13), topology cross-check (FB-12), stamp + drift — into one
   approval. Same pattern that `assess-project.sh` (TD-33 wrapper)
   already established for the read-only side.

Recommend doing both: stamp-preflight is the cheap obvious win (≤30
lines), the wrapper is the strategic win (mirrors `assess-project.sh`
and collapses the whole prepare phase to one shell call).

**Counted approval inventory for `/prepare-deploy` today (from this
session):**

| # | Command type | Source |
|---|---|---|
| 1 | `azd version` + `azd ext list` preflight (raw bash) | FB-8 |
| 2 | H6/H7/H8/H9 file checks (raw bash) | FB-9 |
| 3 | `azd ai agent init --help` probes ×2 | FB-10 |
| 4 | Model selection (Python heredoc on chat-cache) | FB-11 |
| 5 | Topology JSON Python heredoc #1 | FB-12 |
| 6 | Topology JSON Python heredoc #2 | FB-12 |
| 7 | Topology JSON Python heredoc #3 | FB-12 |
| 8 | curl MCP reachability | FB-13 |
| 9 | agent_status init | FB-14 |
| 10 | agent_status update preflight | FB-14 |
| 11 | agent_status update network + drift | FB-14 |
| 12 | safe-azd-init.sh | (clean — script wrapper, one approval) |

**~12 separate approvals** for one `/prepare-deploy` invocation. Target
after Round 1 batch fix: **≤ 4** (preflight, layout verify, topology
read+stamp, `safe-azd-init.sh`).

**Owner / fix.**
- Add `cmd_stamp_preflight` to [agent_status.py](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/agent_status.py).
- New wrapper: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/prepare-deploy.sh` (orchestrates FB-8 preflight + FB-9 layout verify + FB-12 topology read + FB-13 MCP probe + FB-14 stamp + drift).
- Edit [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md) to call the wrapper once instead of orchestrating 4 separate `agent_status.py` calls.

**Status:** closed in v0.27.0.

---

### FB-15 — Scaffold emits `agent.yaml` (ContainerAgent schema) but `azd ai agent init` requires `AgentManifest` schema (with `template:` wrapper) → init fails partway, leaves orphan state

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** **critical — correctness bug, blocks the happy path on a fresh agent**

**What the user saw.** During `/prepare-deploy` for `hello-agent`:

> `azd ai agent init` failed — our `agent.yaml` uses the ContainerAgent
> schema but `azd` expects the `AgentManifest` format (requires a
> `template` field). Per the prompt, I'll fall back to manual `azure.yaml`
> creation.

But the failure was **not clean** — `azd ai agent init` had already
created `azure.yaml`, `.azure/`, and `infra/` before erroring out on the
manifest download step. The user is now in a half-scaffolded state and
the prompt's recovery path is "fall back to manual `azure.yaml`
creation" which contradicts the partial state already on disk.

**Root cause.** Two schemas exist in the skillpack and they are not
interchangeable:

| Schema | Shape | Used by |
|---|---|---|
| **ContainerAgent** ([agent.yaml.template](foundry-agent-skillpack/.apm/skills/foundry-deploy/templates/agent.yaml.template)) | Flat top-level (`kind: hosted` at root) | The REST API (`POST /agents/{name}/versions` body) and `/prepare-deploy` H1 validation |
| **AgentManifest** ([agent.manifest.yaml.template](foundry-agent-skillpack/.apm/skills/foundry-deploy/templates/langgraph-byo/agent.manifest.yaml.template)) | Wraps `template: { kind: hosted, protocols, environment_variables }` + `resources[]` block | `azd ai agent init --manifest` |

The default `/plan-agent` scaffold emits **only the ContainerAgent
form**. `safe-azd-init.sh` accepts a `--manifest` flag and then passes
it through to `azd ai agent init`, which fails because the file at that
path is in the wrong schema. The `langgraph-byo` template is the only
one that ships both, and only because it was written after this gotcha
was discovered.

**What should happen.**

1. **Single source of truth at scaffold time.** `/plan-agent` should
   emit **both** files for hosted agents (`agent.yaml` for the REST API
   + `agent.manifest.yaml` for `azd`), or — preferred — derive one from
   the other at preflight time so the user never authors both.
2. **`safe-azd-init.sh` must validate** that the file passed to
   `--manifest` is in `AgentManifest` schema (presence of top-level
   `template:` key + `metadata:` block). If it sees the `ContainerAgent`
   shape, transform it on the fly (write a temp `agent.manifest.yaml`)
   or emit a clear error with the recovery command (not a "fall back to
   manual" hand-wave).
3. **Failure recovery must be transactional.** If `azd ai agent init`
   fails, `safe-azd-init.sh` should detect the partial state
   (`azure.yaml` + `.azure/` + `infra/` present, but the operation
   exit-coded non-zero) and either: (a) roll back those files, or
   (b) emit a single explicit cleanup command. The current behaviour
   leaves the user in an ambiguous middle state where it's unclear
   whether to re-run `azd init`, edit the existing files, or `rm -rf`.

**Owner / fix.**
- [foundry-agent-skillpack/.apm/skills/foundry-deploy/templates/agent.yaml.template](foundry-agent-skillpack/.apm/skills/foundry-deploy/templates/agent.yaml.template)
  — add a sibling `agent.manifest.yaml.template` for the default
  (non-langgraph) scaffold.
- [foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/safe-azd-init.sh](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/safe-azd-init.sh)
  — add schema validation on `--manifest` arg + transactional cleanup
  on init failure.
- [plan-agent.prompt.md](foundry-agent-skillpack/.apm/prompts/plan-agent.prompt.md)
  Step ~2 (scaffold writes) — emit both files.
- [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md)
  Step H1 — validate both files are present + in the correct schema.
- Document the two-schema gotcha in
  [foundry-deploy/capabilities-manifest.md](foundry-agent-skillpack/.apm/skills/foundry-deploy/capabilities-manifest.md)
  + [foundry-failure-modes](foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md)
  (this is a verified failure mode in the catalog now).

**Status:** closed in v0.27.0.

---

### FB-16 — Manual `azd env set` ceremony for 8 variables instead of one wrapper that reads from `agent-capabilities.yaml`

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (medium — plumbing + duplicates state already on disk)

**What the user saw.** After the FB-15 manual fallback, the prompt
chained 8 `azd env set` calls into one big `&&` block:

```bash
azd env set AZURE_SUBSCRIPTION_ID d194e976-63c4-43c9-995a-5340d0daffb1 && \
azd env set AZURE_RESOURCE_GROUP agents-3iq && \
azd env set AZURE_LOCATION eastus && \
azd env set AZURE_AI_ACCOUNT_NAME foundry-res-eastus && \
azd env set AZURE_AI_PROJECT_NAME proj-foundry-res-eastus && \
azd env set ENABLE_HOSTED_AGENTS true && \
azd env set ENABLE_CAPABILITY_HOST false && \
azd env set ENABLE_MONITORING true
```

Two problems:

1. **Every one of these values already exists in
   `agent-capabilities.yaml` `target:`** (`subscription_id`,
   `resource_group`, `foundry_account`, `project`, `location`) plus the
   capability declarations (`capabilities.{hosted,capability_host,monitoring}`).
   The prompt is hand-translating a manifest into env vars instead of
   reading the manifest.
2. **Raw `azd env set` × 8** in chat is plumbing leak (same family as
   FB-4 / FB-8 / etc.) and creates one approval per call **if not
   chained**, or one giant unreadable `&&` chain if chained.

**What should happen.** A single wrapper script
`foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/sync-azd-env.sh`
that:

1. Reads `<agent_path>/agent-capabilities.yaml` (target + capabilities).
2. Maps known fields to azd env vars via a documented mapping table.
3. Emits one `azd env set` per field, behind a single approval.
4. Reports KV stdout (`AZD_ENV_SYNCED=true`,
   `AZD_ENV_VARS_SET=8`) so the prompt can summarise.

Mapping table lives in the skill so adding a new capability → new env
var is one edit, not a prompt change.

**Owner / fix.**
- New script: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/sync-azd-env.sh`.
- New doc: `foundry-agent-skillpack/.apm/skills/foundry-deploy/azd-env-mapping.md` (the table).
- Edit [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md)
  to call the wrapper after `safe-azd-init.sh` instead of inlining the
  `azd env set` chain.

**Status:** closed in v0.27.0.

---

### FB-17 — Another `azd ai agent add --help | head -25` discovery probe leaked to user

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (low — duplicate of FB-10 pattern, smaller blast radius)

**What the user saw.**

```bash
azd ai agent add --help 2>&1 | head -25
```

This is the same anti-pattern as FB-10: runtime `--help` introspection
to discover available subcommands/flags. Either trust the version
preflight (FB-8) or fold capability detection into `preflight-azd.sh`
silently.

**What should happen.** Same Path A as FB-10: delete the probe. If the
caller passed the FB-8 version floor, the `azd ai agent add` subcommand
exists with the expected shape.

**Owner / fix.** Grep [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md)
for `azd ai agent .* --help` and remove all such probes.

**Status:** closed in v0.27.0.

---

### FB-18 — `azd up` was run twice ("user is forced to run this as well")

**Date:** 2026-06-10
**Reporter:** sathik (verbatim quote: *"and user is forced to run this as well"*)
**Severity:** **high — broken contract**, the prompt claims it owns this step and then makes the user re-run it

**What the user saw.** `/prepare-deploy` ran:

```bash
cd /home/sathik/work/code/foundry/foundry-skillpack-test && azd up
```

…and then the chat **asked the user to run the same command again**:

```bash
cd /home/sathik/work/code/foundry/foundry-skillpack-test && azd up
```

This is broken in three ways:

1. **The first run either succeeded (so the second is a no-op or worse,
   re-deploys), failed (so the second runs in a half-state), or
   timed-out (so the second is a recovery the user has no context
   for).** The prompt doesn't tell the user which case applies.
2. **The prompt's own contract** ([prepare-deploy.prompt.md L150-167](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md))
   says *"APM scaffolds and validates. `azd up` deploys. The `azd ai
   agent` extension builds the image, creates the agent, and assigns
   the Entra Agent ID."* That contract implies the prompt owns the
   `azd up` call. If the user has to run it manually anyway, the prompt
   isn't doing its job; if the prompt did run it, the second
   instruction is noise.
3. **No exit-code handling visible.** Whether `azd up` returned 0 or
   non-zero, the prompt needs to capture, report
   (`[+] azd up succeeded in 4m12s` / `[x] azd up failed at step
   <name>: <error>`), and only then either declare success or hand a
   recovery command to the user.

**What should happen.** `/prepare-deploy` should:

1. Run `azd up` exactly once, capturing exit code + duration + the
   ResourceGroupDeploymentName from `azd env get-values`.
2. On exit 0 → report `[+] azd up succeeded — agent <name> deployed to
   <endpoint>` and hand off to `/configure-rbac` per the lifecycle.
3. On non-zero → report the specific failure (parse stderr for known
   patterns from
   [foundry-failure-modes](foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md))
   and emit a single recovery command, **not** a literal re-run of
   `azd up`.

**Open question for the user (please answer):** what did the first
`azd up` actually output? Did it succeed and the prompt asked you to
re-run anyway, or did it fail mid-deploy? The answer routes the fix
between "remove the duplicate instruction" (if first call succeeded)
vs "add real error handling around the single call" (if first call
failed silently).

**Owner / fix.** [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md)
Step 6 (the `azd up` invocation) — wrap in exit-code capture, parse
stderr, single deterministic result path. Optionally: the
`prepare-deploy.sh` wrapper proposed in FB-14 absorbs this so the entire
phase is one approval and one well-defined exit.

**Status:** closed in v0.27.0.
`azd up` output); contract clarification can land unblocked.

---

### FB-19 — `apm audit` shown raw without context on what to do with the output

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** prompt UX (low — informational)

**What the user saw.**

```bash
cd /home/sathik/work/code/foundry/foundry-skillpack-test && \
apm audit 2>&1
```

The prompt ran `apm audit` (a real and useful command — it checks
installed APM packages for drift / vulnerabilities) but didn't explain
what to do with the output. This is less severe than the other plumbing
leaks because `apm audit` is fast and the output is human-readable, but
the user is still left holding the result without guidance.

**What should happen.** The prompt should parse `apm audit` output and
report:

```
[+] apm audit: 2 packages installed, both at HEAD, no advisories
```

…or:

```
[!] apm audit: foundry-agent-skillpack is 3 commits behind HEAD — run `apm update` to refresh
```

Same KV-emitter pattern as the other proposed wrappers. Or: skip `apm
audit` entirely from `/prepare-deploy` — it's more of a
once-per-session check belonging in `/assess-project` or a new
`/audit-install` command.

**Owner / fix.** Decide ownership (whether `apm audit` belongs in
`/prepare-deploy` at all). If yes: parse + summarise the output. If no:
remove the call.

**Status:** closed in v0.27.0.

---

### FB-20 — `azd up` region inference is wrong: uses RG location, not the existing Foundry project's location → `InvalidResourceLocation` on every cross-region project (FB-18 root cause)

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** **critical — blocks every cross-region BYO deployment, which is the exact scenario TD-34 proved works**

**What the user saw.** `azd up` failed with:

```
ERROR: error executing step command 'provision': deployment failed: error deploying infrastructure: validating deployment to subscription:

Validation Error Details:
InvalidResourceLocation: The resource 'foundry-res-eastus/proj-foundry-res-eastus' already exists in location 'eastus' in resource group 'agents-3iq'. A resource with the same name cannot be created in location 'eastus2'. Please select a new resource name.

TraceID: 149be5e495b4b94e2a57c6e12eb4d16a
```

Root cause confirmed by `azd env get-values`:
- `AZURE_LOCATION` was set to `eastus2` (the RG `agents-3iq`'s home region)
- The existing project `foundry-res-eastus/proj-foundry-res-eastus` lives in `eastus`

This is exactly the **cross-region BYO scenario that TD-34 was built
for and that we empirically proved end-to-end on 2026-06-09**: Foundry
account/project in `eastus`, RG (and shared backing Cosmos/Search/Storage)
in `eastus2`. The skillpack's own success case is the one `azd up`
fails on.

**Recovery the agent had to invent on the spot:**

```bash
azd env set AZURE_LOCATION eastus && \
azd env set USE_EXISTING_AI_PROJECT true
```

That recovery is correct — `USE_EXISTING_AI_PROJECT=true` is the
documented opt-in that tells `azd` to **not** try to create the project
and to read its location from the existing resource — but the user
should never have hit this. The skillpack already knows the project's
location (it's in `agent-capabilities.yaml` `target.location`, and
`/assess-project` emits it as `PROJECT_LOCATION=eastus` in
`project-topology.json`).

**Root cause analysis.**

This is the **direct consequence of FB-16**. The agent set
`AZURE_LOCATION=eastus` (hard-coded in the manual `azd env set` chain),
but somewhere between that and `azd up`, the location got overridden to
`eastus2`. Two candidate sources:

1. **`azd ai agent init`** (the partly-failed init from FB-15) detected
   the RG location (`agents-3iq` in `eastus2`) and stamped it into
   `azure.yaml` / `infra/main.parameters.json` / the `azd` env. The
   manual `azd env set AZURE_LOCATION eastus` was then overwritten by
   the init residue. (User said: *"the azd ai agent init earlier
   warned about this and changed the location."* — confirming this
   hypothesis.)
2. **The generated Bicep** in `infra/main.bicep` probably reads `param
   location = resourceGroup().location`, which is `eastus2` regardless
   of what env var the user sets. Even with
   `AZURE_LOCATION=eastus` in the env, the Bicep parameter defaults to
   the RG's location.

**What should happen.**

Three layered fixes:

1. **Read existing project location authoritatively.** When
   `/prepare-deploy` is targeting an existing project (which is the
   common case after `/assess-project`), it should:
   - Read `target.location` from `agent-capabilities.yaml` (or
     `PROJECT_LOCATION` from `project-topology.json` — FB-12 helper).
   - Set **both** `AZURE_LOCATION=<project_location>` **and**
     `USE_EXISTING_AI_PROJECT=true` via the `sync-azd-env.sh` wrapper
     (FB-16).
   - Pass `--location <project_location>` to `azd ai agent init`
     explicitly so the init step doesn't infer from the RG.

2. **Validate before `azd up`.** A new preflight check:
   `validate-azd-env-location.sh` that diffs `AZURE_LOCATION` (from
   azd env) against `target.location` (from manifest) and refuses to
   run `azd up` if they disagree. Emit:
   ```
   [x] Location mismatch:
       azd env AZURE_LOCATION = eastus2
       manifest target.location = eastus
       Recovery: azd env set AZURE_LOCATION eastus
   ```
   Same recovery the agent invented today, but proactive instead of
   reactive after a 4-minute `azd up` failure.

3. **Document the cross-region BYO contract** explicitly. The
   2026-06-09 TD-34 empirical validation proved the **runtime**
   topology supports cross-region (capHost in eastus, backing in
   eastus2). This finding proves the **deploy-time** tooling does not
   handle the same topology cleanly. Add a section to
   [foundry-deploy/capability-host-bootstrap.md](foundry-agent-skillpack/.apm/skills/foundry-deploy/capability-host-bootstrap.md)
   and a new failure mode to
   [foundry-failure-modes](foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md):
   *"FM-XX: azd up InvalidResourceLocation when project region != RG
   region. Fix: AZURE_LOCATION=<project_region> + USE_EXISTING_AI_PROJECT=true."*

**This is the resolution to FB-18's open question** ("what did the
first `azd up` return"). The first `azd up` failed with the
InvalidResourceLocation error above; the chat's "manually run `azd
up` again" instruction was after the user set the recovery env vars.
So FB-18's fix is "the prompt must classify this specific failure and
emit the recovery as a single command, not as a verbatim re-run of
`azd up`."

**Owner / fix.**
- New script: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/validate-azd-env-location.sh`.
- New script (already in FB-16 plan): `sync-azd-env.sh` — must emit `USE_EXISTING_AI_PROJECT=true` when `target.foundry_account` + `target.project` are populated.
- Edit [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md)
  to call the validator before `azd up`.
- Edit [safe-azd-init.sh](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/safe-azd-init.sh)
  to pass `--location` explicitly when the manifest declares one.
- Document in [capability-host-bootstrap.md](foundry-agent-skillpack/.apm/skills/foundry-deploy/capability-host-bootstrap.md) (cross-region deploy-time contract).
- Add failure mode to [foundry-failure-modes](foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md).

**Status:** closed in v0.27.0.
"`azd up` correctness triad"** of Round 1.

---

### FB-21 — `safe-azd-init.sh` never forks on `deploy_mode: code` → `azd ai agent init` scaffolds the container path → `azure.yaml` gets `language: docker` → `azd deploy` fails on missing Dockerfile

**Date:** 2026-06-10
**Reporter:** sathik
**Severity:** **critical — silently breaks every `deploy_mode: code` deployment, which is the only mode being tested in Round 1**

**What the user saw.** After the FB-20 recovery, `azd up` made it through **`azd provision`** successfully (RG, model deployment, ACR, connection all ✅) but failed on **`azd deploy`**:

> *"azd tried a Docker build because azure.yaml has `language: docker`, but there's no Dockerfile (code-deploy mode). The `azure.yaml` was generated by `azd ai agent init` with container assumptions."*

The agent had to **manually patch `azure.yaml` `language: docker` → `language: py`** to unblock `azd deploy`.

**Root cause (confirmed by grep).**

`agent-capabilities.yaml` correctly declared `deploy_mode: code`. `/plan-agent` Step 0c documents `deploy_mode: code` as the source-code (zip) path and even shows the correct invocation in [plan-agent.prompt.md L127](foundry-agent-skillpack/.apm/prompts/plan-agent.prompt.md#L127):

```bash
azd ai agent init --deploy-mode code --runtime python_3_13 --entry-point main.py --dep-resolution remote_build
```

But [prepare-deploy.prompt.md Step 3](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md#L284-L292) — the step that actually runs the init — calls:

```bash
.agents/skills/foundry-deploy/scripts/safe-azd-init.sh ${input:agent_path} \
  --manifest ${input:agent_path}/agent.yaml \
  --src ${input:agent_path} \
  --model-deployment <MODEL_DEPLOYMENT_NAME> \
  --protocol responses
```

**No `--deploy-mode` flag. No `--runtime`. No `--entry-point`. No `--dep-resolution`.** [safe-azd-init.sh](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/safe-azd-init.sh) is a transparent passthrough — it forwards `$@` to `azd ai agent init`, so whatever the prompt fails to pass, the init never sees.

When `azd ai agent init` runs without `--deploy-mode code`, it silently defaults to the container path (this is documented as a known footgun in [code-deploy.md L159](foundry-agent-skillpack/.apm/skills/foundry-deploy/code-deploy.md#L159): *"Earlier `azd ai agent` extension versions … will silently scaffold the container path"* — but the **same silent default still applies to the current version when the flag is omitted**). The scaffold writes `azure.yaml` with:

```yaml
services:
  agent:
    language: docker  # ← wrong for deploy_mode: code
    project: ./agents/my-agent
    host: containerapp
```

`azd provision` succeeds because the Bicep doesn't care about `language`. `azd deploy` then tries to build a Docker image, finds no Dockerfile, and dies. The user is left mid-deploy, has to manually edit `azure.yaml`, then re-run `azd deploy`.

**Why this slipped past every guardrail.**

- **FB-15 (schema mismatch) blocks the init outright** if the agent emitted the wrong `agent.yaml` schema. FB-21 is **worse**: the init *succeeds*, so no guardrail trips. The breakage doesn't surface until 3–4 minutes into `azd deploy` after Bicep has already provisioned real cloud resources.
- The H10 preflight in [prepare-deploy.prompt.md L148-L150](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md#L148-L150) verifies the **extension supports `--deploy-mode code`** but the prompt then never **uses** the flag it just verified.
- [code-deploy.md L159](foundry-agent-skillpack/.apm/skills/foundry-deploy/code-deploy.md#L159) explicitly calls out the "silently scaffold the container path" failure mode — but only in the context of "old extension version", not "current extension version with flag omitted".

**What should happen.**

Four-part fix (this is structural, not cosmetic):

1. **`/prepare-deploy` Step 3 must fork on `deploy_mode`.** Read it once from `agent-capabilities.yaml` (or from the topology helper added in FB-12) and assemble the correct flag set:

   ```bash
   # If deploy_mode: container (default):
   .agents/skills/foundry-deploy/scripts/safe-azd-init.sh ${input:agent_path} \
     --manifest ${input:agent_path}/agent.yaml \
     --src ${input:agent_path} \
     --model-deployment $MODEL_DEPLOYMENT_NAME \
     --protocol responses

   # If deploy_mode: code:
   .agents/skills/foundry-deploy/scripts/safe-azd-init.sh ${input:agent_path} \
     --manifest ${input:agent_path}/agent.yaml \
     --src ${input:agent_path} \
     --model-deployment $MODEL_DEPLOYMENT_NAME \
     --protocol responses \
     --deploy-mode code \
     --runtime $CODE_RUNTIME \
     --entry-point $CODE_ENTRY_POINT \
     --dep-resolution $CODE_DEP_RESOLUTION
   ```

2. **`safe-azd-init.sh` must validate the deploy mode is what the manifest declared** before running `azd ai agent init`. Read `deploy_mode` from the `--manifest` file (it's in `agent-capabilities.yaml`, not `agent.yaml` directly — needs cross-file lookup) and refuse to run if `--deploy-mode` flag is missing when manifest says `code`. Emit:

   ```
   [x] Manifest declares deploy_mode: code but no --deploy-mode flag passed.
       This would scaffold the container path. Recovery: add --deploy-mode code --runtime <r> --entry-point <e> --dep-resolution <d>
   SAFE_AZD_INIT=deploy-mode-mismatch
   ```

3. **Post-init validation.** After `azd ai agent init` succeeds, a new `validate-azure-yaml.sh` reads the generated `azure.yaml` and checks:
   - `services.<svc>.language == "py"` (or `dotnetcore`) when `deploy_mode: code`
   - `services.<svc>.language == "docker"` when `deploy_mode: container`
   - `services.<svc>.docker` block absent when `language: py`
   - `Dockerfile` exists when `language: docker`

   If mismatch, emit the exact `sed` / `yq` command to patch and STOP before `azd up`. (Or — better — call `azd ai agent init` again with the correct flags after cleanup.)

4. **Failure-mode catalog entry.** Add to [foundry-failure-modes](foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md):

   > **FM-XX: `azd deploy` "Dockerfile not found" / "language: docker" mismatch.**
   > **Symptom:** `azd provision` succeeds, `azd deploy` fails with Docker build error or missing Dockerfile.
   > **Cause:** `azd ai agent init` was run without `--deploy-mode code` despite `deploy_mode: code` in `agent-capabilities.yaml`.
   > **Fix:** patch `azure.yaml` `language: docker` → `language: py`, remove `services.<svc>.docker` block if present, re-run `azd deploy`. Permanent fix: re-run `azd ai agent init --deploy-mode code` (after deleting `azure.yaml`).

**This finding compounds FB-15 and FB-20.** All three are "the scaffold step doesn't pass / honor the inputs it already knows about." Round 1's `azd up` correctness story is now a **quadruple**, not a triad:

| # | Bug | Symptom | Root cause |
|---|-----|---------|------------|
| FB-15 | Schema mismatch | `azd ai agent init` fails partway | Scaffold emits ContainerAgent, init expects AgentManifest |
| FB-18 | `azd up` re-run | User runs `azd up` twice | First run hits FB-20, prompt doesn't classify |
| FB-20 | Wrong region | `InvalidResourceLocation` | `AZURE_LOCATION` defaulted to RG location, not project location |
| **FB-21** | **Wrong deploy mode** | **`azd deploy` Docker build fails** | **`--deploy-mode code` flag omitted despite manifest declaring `deploy_mode: code`** |

All four belong in the same batch fix. FB-21 is the most insidious because `azd provision` succeeds first — the user has burned real cloud resources before the bug surfaces.

**Owner / fix.**
- Edit [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md) Step 3 to fork on `deploy_mode` and assemble the correct flag set.
- Edit [safe-azd-init.sh](foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/safe-azd-init.sh) to read `deploy_mode` from the manifest and validate `--deploy-mode` flag matches before running `azd ai agent init`.
- New script: `foundry-agent-skillpack/.apm/skills/foundry-deploy/scripts/validate-azure-yaml.sh` — post-init schema check (language matches deploy_mode, Dockerfile presence matches, no orphan docker block).
- Edit [prepare-deploy.prompt.md](foundry-agent-skillpack/.apm/prompts/prepare-deploy.prompt.md) Step 3 to call the validator after `safe-azd-init.sh` succeeds, before Step 4.
- Add failure mode FM-XX to [foundry-failure-modes/SKILL.md](foundry-agent-skillpack/.apm/skills/foundry-failure-modes/SKILL.md).
- Update [code-deploy.md L159](foundry-agent-skillpack/.apm/skills/foundry-deploy/code-deploy.md#L159) note to call out that even on **current** extension versions, omitting `--deploy-mode code` silently scaffolds container path — not just an "old extension" bug.

**Status:** closed in v0.27.0.

---

## Template for new entries

```markdown
### FB-N — One-line title of the issue

**Date:** YYYY-MM-DD
**Reporter:** <name>
**Severity:** docs | prompt UX | script bug | RBAC | other

**What the user saw.** Concrete steps + exact error / output.

**What should happen.** Expected behavior, with reference to the prompt /
script / doc file.

**Owner / fix.** File(s) to edit. Drift-check + apm-install verification.

**Status:** open | in-progress | fixed in <commit-sha>
```
