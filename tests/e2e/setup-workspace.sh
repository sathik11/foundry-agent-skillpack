#!/usr/bin/env bash
# setup-workspace.sh — F-K: prepare a CLEAN, NON-GIT workspace with the skillpack apm-installed.
#
# Why this exists (F-J → F-K, see tests/e2e/ITERATION-LOG.md):
#   `azd ai agent init` scaffolds a self-contained project that runs its own `git` staging.
#   When the E2E ran inside the skillpack's own git worktree, that staging broke
#   (`pathspec '*' did not match`). The fix — and the only faithful reproduction of real usage —
#   is to drive the journey in a directory that is NOT inside any git repository, with the
#   skillpack installed exactly the way a real user installs it (`apm install`).
#
# This produces the same on-disk layout a user gets in THEIR project:
#   .opencode/agents/foundry-engineer.md, .opencode/commands/*.md   (driver persona + commands)
#   .agents/skills/foundry-deploy/scripts/*.sh, .../templates/...    (scripts + templates)
#   apm_modules/_local/...                                           (reference-doc cache)
#
# Usage:
#   setup-workspace.sh --dest <dir> --src <skillpack-repo-root> [--targets opencode,agent-skills] [--force]
#
# On success the LAST line of stdout is the machine-readable workspace path:
#   WORKSPACE=<absolute path>
set -euo pipefail

DEST=""
SRC=""
FORCE=0
TARGETS="opencode,agent-skills"

while [ $# -gt 0 ]; do
  case "$1" in
    --dest)    DEST="${2:?--dest needs a value}"; shift 2 ;;
    --src)     SRC="${2:?--src needs a value}"; shift 2 ;;
    --targets) TARGETS="${2:?--targets needs a value}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "[!] unknown arg: $1" >&2; exit 2 ;;
  esac
done

[ -n "$DEST" ] || { echo "[!] --dest is required" >&2; exit 2; }
[ -n "$SRC" ]  || { echo "[!] --src is required" >&2; exit 2; }

command -v apm >/dev/null 2>&1 || { echo "[!] apm CLI not on PATH (need Agent Package Manager)" >&2; exit 2; }

SRC="$(cd "$SRC" && pwd)"
[ -d "$SRC/foundry-agent-skillpack" ] || {
  echo "[!] no foundry-agent-skillpack/ under --src $SRC" >&2; exit 2; }

mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# --- F-K core guarantee: the workspace must NOT be inside a git repo. ---------------------------
if git -C "$DEST" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "[!] $DEST is inside a git repository." >&2
  echo "    F-K requires a NON-git workspace (azd template staging breaks otherwise — see F-J)." >&2
  echo "    Pick a --dest outside any git tree, e.g. \$HOME/.cache/foundry-skillpack-e2e/<id>." >&2
  exit 3
fi

# --- Empty/refresh the destination ------------------------------------------------------------
if [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
  if [ "$FORCE" = "1" ]; then
    echo "[setup] --force: clearing existing contents of $DEST"
    rm -rf "${DEST:?}/"* "${DEST:?}/".[!.]* "${DEST:?}/".??* 2>/dev/null || true
  else
    echo "[!] $DEST is not empty. Re-run with --force to clear it." >&2
    exit 4
  fi
fi

# --- Install the local skillpack + playbook the way a user would -------------------------------
DEPS=("$SRC/foundry-agent-skillpack")
[ -d "$SRC/foundry-agent-playbook" ] && DEPS+=("$SRC/foundry-agent-playbook")

echo "[setup] installing into $DEST"
echo "[setup]   source : $SRC"
echo "[setup]   deps   : ${DEPS[*]##*/}"
echo "[setup]   targets: $TARGETS"
( cd "$DEST" && apm install "${DEPS[@]}" --target "$TARGETS" )

# --- Verify the install produced everything the scenario depends on ----------------------------
NEED=(
  ".opencode/agents/foundry-engineer.md"
  ".opencode/commands/prepare-deploy.md"
  ".agents/skills/foundry-deploy/scripts/assess-project.sh"
  ".agents/skills/foundry-deploy/scripts/prepare-deploy.sh"
  ".agents/skills/foundry-deploy/templates/agent.manifest.yaml.template"
  ".agents/skills/foundry-deploy/templates/main.py.template"
)
missing=0
for p in "${NEED[@]}"; do
  if [ ! -e "$DEST/$p" ]; then echo "[!] missing after install: $p" >&2; missing=1; fi
done
[ "$missing" = "0" ] || { echo "[!] install verification failed" >&2; exit 5; }

echo "[setup] OK — clean non-git workspace ready"
echo "WORKSPACE=$DEST"
