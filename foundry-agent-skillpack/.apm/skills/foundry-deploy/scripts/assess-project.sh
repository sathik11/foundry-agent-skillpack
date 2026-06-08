#!/usr/bin/env bash
# TD-33 wrapper for /assess-project — collapses the three-script
# round-trip (preflight + discover + format) into a single invocation so the
# prompt's happy path is one tool call instead of three.
#
# Why a wrapper instead of inlining in the prompt?
#   * The prompt previously chained: preflight-roles.sh → discover-project-topology.sh
#     → discover-project-topology.py. Each was a separate `run_in_terminal` call.
#     Three calls means three turns of latency + three places to fail silently.
#   * Composing in bash lets us propagate the discover script's exit-4
#     ambiguous-account signal cleanly back to the agent for picklist dispatch.
#   * Preflight is best-effort (the alias `assess-project` may not be in
#     preflight-roles.sh on older installs). We surface the warning but
#     never block — `/assess-project` is read-only, the API returns 403
#     clearly enough on its own.
#
# Usage:
#   ./assess-project.sh <subscription_id> <resource_group> \
#       [<account_name>] [<project_name>] [<out_dir>]
#
# Exit codes (propagated from discover-project-topology.sh):
#   0 — assessment complete, ASSESSMENT_REPORT=<path> emitted on stdout
#   2 — account found but not Foundry-grade (allowProjectManagement != true)
#   3 — no CognitiveServices/AIServices account in resource group
#   4 — ambiguous: multiple foundry-grade accounts/projects, no hint given.
#       Candidate list is on stdout as ACCOUNT_NAME_<n>= / PROJECT_NAME_<n>=
#       keys (read /tmp/assess-project.kv); the prompt's Step 2 dispatches
#       a picklist and re-invokes with the chosen hint.
#   other — discovery/format failure; check stderr.
set -euo pipefail

SUB="${1:?usage: $0 <sub> <rg> [<account>] [<project>] [<out_dir>]}"
RG="${2:?usage: $0 <sub> <rg> [<account>] [<project>] [<out_dir>]}"
ACCT="${3:-}"
PROJ="${4:-}"
OUT_DIR="${5:-./assessment}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve sibling scripts. The skillpack is installed under .agents/, so the
# discover scripts live next to this one. The roles preflight is one skill
# directory over.
DISCOVER_SH="${SCRIPT_DIR}/discover-project-topology.sh"
DISCOVER_PY="${SCRIPT_DIR}/discover-project-topology.py"
ROLES_PREFLIGHT="${SCRIPT_DIR}/../../foundry-roles/scripts/preflight-roles.sh"

for f in "$DISCOVER_SH" "$DISCOVER_PY"; do
  if [[ ! -x "$f" && ! -r "$f" ]]; then
    echo "[x] Missing sibling script: $f" >&2
    exit 70  # EX_SOFTWARE
  fi
done

# ----------------------------------------------------------------------------
# Step 0 — Preflight (best-effort, non-blocking)
# ----------------------------------------------------------------------------
echo "[i] /assess-project wrapper — step 0: caller RBAC preflight (best-effort)" >&2
if [[ -x "$ROLES_PREFLIGHT" ]]; then
  # `assess-project` alias may not exist on older preflight-roles.sh.
  # Capture stderr to a tmp file so we can show it on failure but never block.
  if ! bash "$ROLES_PREFLIGHT" assess-project "$SUB" "$RG" "$ACCT" "$PROJ" \
       >/tmp/assess-project-preflight.out 2>/tmp/assess-project-preflight.err; then
    PREFLIGHT_RC=$?
    if [[ $PREFLIGHT_RC -eq 64 ]]; then
      echo "[i] preflight-roles.sh doesn't know the 'assess-project' alias (older install). Skipping — read-only API surfaces 403 clearly on its own." >&2
    else
      echo "[!] Preflight reported rc=$PREFLIGHT_RC. Continuing read-only (the discover script will surface 403s clearly):" >&2
      tail -8 /tmp/assess-project-preflight.err >&2 || true
    fi
  fi
else
  echo "[i] preflight-roles.sh not found at $ROLES_PREFLIGHT — skipping." >&2
fi

# ----------------------------------------------------------------------------
# Step 1 — Discovery (KEY=VALUE stream to /tmp/assess-project.kv)
# ----------------------------------------------------------------------------
echo "[i] /assess-project wrapper — step 1: discovery (read-only)" >&2
KV_OUT="/tmp/assess-project.kv"
DISC_ERR="/tmp/assess-project-discover.err"

set +e
bash "$DISCOVER_SH" "$SUB" "$RG" "$ACCT" "$PROJ" >"$KV_OUT" 2>"$DISC_ERR"
DISC_RC=$?
set -e

if [[ $DISC_RC -ne 0 ]]; then
  # Always tail discovery stderr — invariant #9 forbids silent swallow.
  echo "[!] discover-project-topology.sh exit=$DISC_RC. Last 15 lines of stderr:" >&2
  tail -15 "$DISC_ERR" >&2 || true
  if [[ $DISC_RC -eq 4 ]]; then
    # Ambiguous: still emit the candidate list on stdout so the prompt's
    # picklist dispatch can grep ACCOUNT_NAME_<n>= / PROJECT_NAME_<n>=.
    cat "$KV_OUT"
    echo "ASSESSMENT_STATUS=ambiguous"
    echo "ASSESSMENT_KV_FILE=$KV_OUT"
  fi
  exit $DISC_RC
fi

# ----------------------------------------------------------------------------
# Step 2 — Format (markdown + JSON + stub)
# ----------------------------------------------------------------------------
echo "[i] /assess-project wrapper — step 2: formatting verdicts → $OUT_DIR" >&2
mkdir -p "$OUT_DIR"

FMT_ERR="/tmp/assess-project-format.err"
set +e
python3 "$DISCOVER_PY" --input "$KV_OUT" --out-dir "$OUT_DIR" 2>"$FMT_ERR"
FMT_RC=$?
set -e

if [[ $FMT_RC -ne 0 ]]; then
  echo "[!] discover-project-topology.py exit=$FMT_RC. Last 15 lines of stderr:" >&2
  tail -15 "$FMT_ERR" >&2 || true
  exit $FMT_RC
fi

# ----------------------------------------------------------------------------
# Final — emit machine-readable pointers the prompt can pick up in one read
# ----------------------------------------------------------------------------
REPORT_MD="$OUT_DIR/project-topology.md"
REPORT_JSON="$OUT_DIR/project-topology.json"
STUB_YAML="$OUT_DIR/agent-capabilities.draft.yaml"

echo "ASSESSMENT_STATUS=ok"
echo "ASSESSMENT_KV_FILE=$KV_OUT"
echo "ASSESSMENT_REPORT_MD=$REPORT_MD"
echo "ASSESSMENT_REPORT_JSON=$REPORT_JSON"
[[ -f "$STUB_YAML" ]] && echo "ASSESSMENT_STUB_YAML=$STUB_YAML" || true

echo "[+] /assess-project complete." >&2
echo "    Report:   $REPORT_MD" >&2
echo "    JSON:     $REPORT_JSON" >&2
[[ -f "$STUB_YAML" ]] && echo "    Stub:     $STUB_YAML" >&2 || true
