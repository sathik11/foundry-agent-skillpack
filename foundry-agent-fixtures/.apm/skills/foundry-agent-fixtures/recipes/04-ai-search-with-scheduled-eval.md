---
validity_date: 2026-05-14
audience: You have (or can create) an AI Search index; want a published-version gate
duration: ~45 minutes
surfaces: [agent_framework_runtime, ai_search_direct, scheduled_eval]
prerequisites:
  - Recipe 01 or 02 completed
  - AI Search service with RBAC enabled and a populated index
  - Caller has `Owner` or `User Access Administrator` on the search service (to grant Phase B)
  - A small JSONL regression dataset (example below)
---

# Recipe 04 — AI Search Direct + Scheduled Eval (Publish Gate)

> **Goal:** Attach a single AI Search index to your agent (managed-identity auth, no API keys), then wire a scheduled evaluation that runs nightly against a held-out regression set. End state: a publish-blocking quality gate — if `task_adherence` or `groundedness` drop below threshold, `/verify-agent` refuses the publish.

3 surfaces: **agent runtime + AI Search direct + scheduled eval gating publish**.

## Surface map

| Surface | Choice |
|---|---|
| Agent runtime | `agent-framework` |
| Knowledge | `ai_search_direct` (single index, managed-identity auth) |
| Outer loop | Scheduled evaluation with `pass_threshold` enforced by `/verify-agent` |

> **Why scheduled, not continuous?** Continuous eval samples production traffic — you can't *gate publishes* on it because traffic to the new version is what generates the data. Scheduled runs against a fixed dataset, so you can compare like-for-like across versions and block bad ones.

## Step 1 — Author your regression dataset

Create `agents/<your-name>/eval/regression-set.jsonl` (one JSON object per line):

```json
{"query": "What is our refund policy?", "ground_truth": "Refunds within 30 days, original payment method."}
{"query": "How do I file a support ticket?", "ground_truth": "Email support@contoso.com or use the in-app form."}
{"query": "When was the company founded?", "ground_truth": "1998."}
```

Keep it ≤100 rows for v1 — the eval cost is per row × per evaluator.

✅ **Checkpoint.** File exists, valid JSONL, every row has at minimum `query` and `ground_truth`.

---

## Step 2 — Update manifest with knowledge + scheduled eval

```yaml
schema_version: 1
agent_kind: hosted

capabilities:
  knowledge:
    sources:
      - name: kb-direct
        kind: ai_search_direct
        resource_id: /subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Search/searchServices/<search>
        index_name: docs-v2
        auth: managed_identity                  # never api_key — broken with private VNet
        semantic_config: default                # required for query rewrite

  evals:
    role: orchestrator
    judge_model: gpt-4.1-mini

    continuous:
      enabled: true                              # keep continuous on too — cheap insurance
      sample_rate: 0.1
      max_hourly_runs: 50

    scheduled:
      enabled: true
      cron: "0 2 * * *"                          # daily 02:00 UTC
      timezone: UTC
      dataset:
        kind: jsonl
        path: ./eval/regression-set.jsonl
      evaluators:                                # explicit — uses ground_truth
        - id: task_adherence
        - id: groundedness
      pass_threshold:
        task_adherence: 4.0
        groundedness: 4.0

  network:
    class: public
```

✅ **Checkpoint.** Manifest saved.

---

## Step 3 — Preflight + deploy

```
/prepare-deploy agent_path=agents/<your-name>
azd up
```

The preflight verifies:
- `ai_search_direct`: search service exists, RBAC enabled, index present, semantic ranker available.
- `evals.scheduled`: `Azure AI User` on the project, judge model deployed, dataset file readable.

Common ❌:
- "Index `docs-v2` not found" — case-sensitive; verify exact name.
- "Semantic config `default` not on index" — open the index schema; either add a semantic config or change the manifest.
- "Search service has key auth only" — enable RBAC: Settings → Keys → Role-based access control.

✅ **Checkpoint.** Agent deploys; `agent-status.json` `preflight.capabilities.knowledge` shows ✅.

---

## Step 4 — Apply RBAC

```
/configure-rbac agent_path=agents/<your-name> agent_name=<your-name>
```

Phase B for this recipe:
- **Project MI → `Search Index Data Reader`** on the search service. Stamped into `agent-status.json` `rbac.capability_grants.knowledge.ai_search_direct.kb-direct`.

> Wait 5–15 minutes.

---

## Step 5 — Wire the scheduled eval

```
/setup-evals agent_name=<your-name> agent_path=agents/<your-name>
```

The prompt now does **two** things (one per declared eval block):

1. **Continuous eval** — same as Recipe 01. Idempotent; safe to re-run.
2. **Scheduled eval** — runs `ensure_scheduled_eval.py`:
   - Uploads `eval/regression-set.jsonl` as a Foundry dataset (versioned by content hash — re-uploads of the same file return the same dataset id).
   - Creates the `EvaluationRule` + `ProjectsSchedule` with the cron above.
   - Stamps `agent-status.json` `evals.scheduled_rule_id`.

Review the dry-run plan; confirm.

✅ **Checkpoint.** Foundry portal → your agent → **Evaluation** tab shows the scheduled eval rule. `agent-status.json` `evals` block populated.

---

## Step 6 — Force a first run + verify

The schedule will fire at 02:00 UTC. To verify immediately:

1. Go to Foundry portal → your agent → Evaluation → the scheduled rule.
2. Click **Run now**.
3. Wait ~1–5 minutes (depends on dataset size + model latency).

Open the run; you should see one row per dataset entry with scores for `task_adherence` and `groundedness`. The aggregate scores appear in the rule summary.

### How the publish gate works

The `pass_threshold` in the manifest is enforced by `/verify-agent` Step 7 (the `verify` block stamp). When a new agent version is deployed and `/verify-agent` runs:

- It reads `evals.scheduled.pass_threshold` from the manifest.
- It queries the latest scheduled-eval run.
- If any threshold is below the floor, `verify.last_run_status: fail` + a structured reason; the prompt refuses to mark the version as "publish-ready."

> The gate is *advisory* in this version of the skillpack — it sets `verify.last_run_status` but doesn't actively prevent `azd ai agent version set-default`. Wire the gate into your deployment pipeline by checking `agent-status.json verify.last_run_status == "pass"` before promoting.

✅ **Checkpoint.** First scheduled run completes. `agent-status.json` `verify.last_run_status: pass` (assuming the agent is good — try editing `main.py` to give wrong answers and re-running to see the gate fire).

---

## Recap — what you proved

| Surface | Evidence |
|---|---|
| Agent runtime | Agent reaches active; serves grounded responses |
| Knowledge — AI Search direct | Index queries succeed; managed-identity auth (no API keys) |
| Outer loop — Scheduled eval | Rule + schedule exist; first run completes; thresholds gate `/verify-agent` |

## Operational pattern — promoting a new version

1. Edit `main.py` / templates / capabilities.
2. `azd up` → new version `vN+1` is created (immutable).
3. `/verify-agent` runs on `vN+1` (reads scheduled-eval results).
4. If `pass`: `azd ai agent version set-default vN+1`.
5. If `fail`: review the eval report; iterate; create `vN+2`; re-verify.

## Cleanup

```bash
azd down --purge
# Delete the eval rule + schedule (re-run wrapper with --enabled false if/when delete is exposed):
# (no separate delete script today — deletion via portal: Evaluation tab → rule → ⋯ → Delete)
```

## Where to go next

- Add Foundry IQ on top to span multiple sources → [03-knowledge-with-purview.md](03-knowledge-with-purview.md).
- Add cloud red-team scans (region-permitting) → [foundry-evals/redteam.md](../../../../foundry-agent-skillpack/.apm/skills/foundry-evals/redteam.md).
- Front the AI Search calls through APIM → [05-apim-fronted-mcp.md](05-apim-fronted-mcp.md) (substitute MCP for AI Search; same pattern).
