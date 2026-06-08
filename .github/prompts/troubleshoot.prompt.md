---
description: Diagnose a Foundry agent failure from symptoms using the verified failure-modes catalog
input:
  - symptom: "Describe what happened — error message, HTTP code, or observed behavior"
  - agent_name: "Which agent is affected (optional)"
---

# Troubleshoot: ${input:agent_name}

Use the **foundry-failure-modes** skill to match the symptom to a known fix.

## Step 1 — Match Symptom

Read the user's description: "${input:symptom}"

Search the failure-modes skill for a matching entry. Key patterns:

| If symptom contains... | Check failure... |
|---|---|
| `400`, `EnvVarReserved` | F-01 |
| `ImageError`, `failed` | F-03 |
| `403`, `Forbidden` | F-06 or F-07 |
| `PrincipalTypeNotSupported` | F-04 |
| `Model must match` | F-08 |
| `timeout`, `120s` | F-09 |
| `0 rows`, `no records` | F-10 |
| `unable to retrieve` | F-11 |
| `tool name`, `dots` | F-12 |
| `ImportError`, `_telemetry` | F-14 |
| stream cuts, silent close | F-17 |
| intermittent 408 | F-18 |
| `server_error`, large payload | F-19 |
| eval `Failed`, no trace data | F-24 |

## Step 2 — Apply Fix

Provide the specific fix from the failure-modes skill. Include:
1. Root cause explanation (one sentence)
2. Exact fix command or code change
3. Verification step ("Run X to confirm the fix worked")

## Step 3 — If No Match

If the symptom doesn't match any known failure:
1. Ask the user for: full error message, HTTP status code, agent version status
2. Check the agent version GET response for `last_error` / `status_message`
3. Check App Insights for recent error traces:
   ```kql
   exceptions | where cloud_RoleName == "${input:agent_name}" | take 10
   ```
4. Report findings and suggest next investigation step

### Scenario 4 hook — symptom matches a topology gap pattern

If the symptom contains any of `eval traces missing`, `continuous-eval not appearing`, `no rule fired`, `capability host`, `thread store unavailable`, `connection not found`, `AzureAISearch not bound`, `capabilityHost`, `Foundry-grade`, OR the failure-modes match was inconclusive AND the symptom mentions a *missing resource* shape, re-check the project topology before going deeper:

- If `./assessment/project-topology.json` exists in CWD, read it and look for ❌ / ⚠ verdicts in the matching category. Surface the verdict + reference inline.
- Otherwise, suggest running `/assess-project subscription_id=<sub> resource_group=<rg>` first — many "agent runs but the eval / knowledge / memory path is empty" symptoms reduce to a missing project-level binding the failure-modes catalog cannot see.

This is opt-in and additive. Continue with Step 4 if topology is clean.

## Step 4 — Document New Failure

If this is a genuinely new failure mode, suggest adding it to the failure-modes catalog
with: symptom, root cause, fix, and how it was discovered.
