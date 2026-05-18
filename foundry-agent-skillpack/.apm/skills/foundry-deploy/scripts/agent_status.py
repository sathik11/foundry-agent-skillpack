#!/usr/bin/env python3
"""agent-status.json helper — the only writer of per-agent durable state.

Schema: see foundry-deploy/agent-status-schema.md (v1, 2026-05-14).

Subcommands:
  init    — create the file if it doesn't exist (idempotent)
  read    — print the file (or a dotted-field subset)
  update  — merge a JSON section, OR set a value at a dotted path
  hash    — print sha256:12 of agent-capabilities.yaml
  drift   — exit 1 if capabilities hash differs from drift.capability_hash_at_rbac

All writes are atomic (.tmp + rename) and emit pretty JSON with trailing newline
so git diffs are readable.

Standalone — only Python stdlib required for read/update/hash/drift.
"""
from __future__ import annotations

import argparse
import getpass
import hashlib
import json
import os
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_URL = (
    "https://github.com/sathik11/foundry-agent-skillpack/blob/main/"
    "foundry-agent-skillpack/.apm/skills/foundry-deploy/agent-status-schema.md"
)
SCHEMA_VERSION = 1
STATUS_FILENAME = "agent-status.json"
CAPS_FILENAME = "agent-capabilities.yaml"

# Allowed top-level sections. Loose schema: we enforce section names; fields within
# are free. Tighten in a later schema_version if churn warrants.
ALLOWED_SECTIONS = {
    "identities", "deploy", "preflight", "network", "rbac", "evals", "verify", "drift",
    "publish",
}


# ── IO helpers ──────────────────────────────────────────────────────────────

def _status_path(agent_path: str) -> Path:
    return Path(agent_path) / STATUS_FILENAME


def _caps_path(agent_path: str) -> Path:
    return Path(agent_path) / CAPS_FILENAME


def _load(agent_path: str) -> dict[str, Any]:
    p = _status_path(agent_path)
    if not p.exists():
        raise FileNotFoundError(
            f"{p} does not exist. Run: agent_status.py init --agent-path {agent_path} ..."
        )
    with p.open() as fh:
        data = json.load(fh)
    return _maybe_migrate(data)


def _save(agent_path: str, data: dict[str, Any]) -> None:
    p = _status_path(agent_path)
    p.parent.mkdir(parents=True, exist_ok=True)
    data["last_updated"] = _now()
    data["last_actor"] = _whoami()
    body = json.dumps(data, indent=2, sort_keys=False) + "\n"
    # Atomic write
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), prefix=".agent-status.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        os.replace(tmp, p)
    except Exception:
        Path(tmp).unlink(missing_ok=True)
        raise


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _whoami() -> str:
    # Try az signed-in user; fall back to OS user.
    if os.environ.get("AGENT_STATUS_ACTOR"):
        return os.environ["AGENT_STATUS_ACTOR"]
    try:
        import subprocess
        upn = subprocess.check_output(
            ["az", "ad", "signed-in-user", "show", "--query", "userPrincipalName", "-o", "tsv"],
            stderr=subprocess.DEVNULL, text=True, timeout=5,
        ).strip()
        if upn:
            return upn
    except Exception:
        pass
    try:
        return getpass.getuser()
    except Exception:
        return "unknown"


def _maybe_migrate(data: dict[str, Any]) -> dict[str, Any]:
    v = data.get("schema_version", 0)
    if v == SCHEMA_VERSION:
        return data
    if v < SCHEMA_VERSION:
        # Place future _migrate_v{n}_to_v{n+1} calls here in order.
        data["schema_version"] = SCHEMA_VERSION
        return data
    print(
        f"[!] agent-status.json schema_version={v} is newer than helper "
        f"({SCHEMA_VERSION}). Upgrade the package or pin to that version.",
        file=sys.stderr,
    )
    sys.exit(2)


# ── Capability hash ─────────────────────────────────────────────────────────

def _caps_hash(agent_path: str) -> str | None:
    p = _caps_path(agent_path)
    if not p.exists():
        return None
    h = hashlib.sha256(p.read_bytes()).hexdigest()
    return h[:12]


# ── Dotted-path accessors ───────────────────────────────────────────────────

def _get_path(data: dict[str, Any], path: str) -> Any:
    cur: Any = data
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _set_path(data: dict[str, Any], path: str, value: Any) -> None:
    parts = path.split(".")
    cur = data
    for part in parts[:-1]:
        if part not in cur or not isinstance(cur[part], dict):
            cur[part] = {}
        cur = cur[part]
    cur[parts[-1]] = value


def _deep_merge(dst: dict[str, Any], src: dict[str, Any]) -> dict[str, Any]:
    for k, v in src.items():
        if k in dst and isinstance(dst[k], dict) and isinstance(v, dict):
            _deep_merge(dst[k], v)
        else:
            dst[k] = v
    return dst


# ── Subcommands ─────────────────────────────────────────────────────────────

def cmd_init(args: argparse.Namespace) -> int:
    p = _status_path(args.agent_path)
    if p.exists():
        print(f"[i] {p} exists; init is a no-op.")
        return 0
    data = {
        "_schema_url": SCHEMA_URL,
        "schema_version": SCHEMA_VERSION,
        "agent_name": args.agent_name,
        "agent_path": args.agent_path,
        "agent_kind": args.agent_kind,
        "last_updated": _now(),
        "last_actor": _whoami(),
    }
    _save(args.agent_path, data)
    print(f"[+] Initialized {p}")
    return 0


def cmd_read(args: argparse.Namespace) -> int:
    try:
        data = _load(args.agent_path)
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    if args.field:
        value = _get_path(data, args.field)
        if value is None:
            print(f"[!] Field '{args.field}' not present.", file=sys.stderr)
            return 1
        if isinstance(value, (dict, list)):
            print(json.dumps(value, indent=2))
        else:
            print(value)
    else:
        print(json.dumps(data, indent=2))
    return 0


def cmd_update(args: argparse.Namespace) -> int:
    if not (args.section or args.path):
        print("[x] Provide either --section or --path.", file=sys.stderr)
        return 64
    if args.section and args.path:
        print("[x] --section and --path are mutually exclusive.", file=sys.stderr)
        return 64

    try:
        payload = json.loads(args.json)
    except json.JSONDecodeError as exc:
        print(f"[x] --json is not valid JSON: {exc}", file=sys.stderr)
        return 64

    try:
        data = _load(args.agent_path)
    except FileNotFoundError:
        print(
            f"[x] {STATUS_FILENAME} not found. Run 'init' first.",
            file=sys.stderr,
        )
        return 1

    if args.section:
        if args.section not in ALLOWED_SECTIONS:
            print(
                f"[x] Unknown section '{args.section}'. "
                f"Allowed: {', '.join(sorted(ALLOWED_SECTIONS))}",
                file=sys.stderr,
            )
            return 64
        if not isinstance(payload, dict):
            print("[x] --section requires --json to be an object.", file=sys.stderr)
            return 64
        data.setdefault(args.section, {})
        if not isinstance(data[args.section], dict):
            print(f"[x] Existing '{args.section}' is not an object; refusing to merge.", file=sys.stderr)
            return 1
        _deep_merge(data[args.section], payload)
    else:
        # Path-based set
        top = args.path.split(".", 1)[0]
        if top not in ALLOWED_SECTIONS:
            print(
                f"[x] Path must start with one of: {', '.join(sorted(ALLOWED_SECTIONS))}. Got '{top}'.",
                file=sys.stderr,
            )
            return 64
        _set_path(data, args.path, payload)

    _save(args.agent_path, data)
    print(f"[+] Updated {_status_path(args.agent_path)}")
    return 0


def cmd_hash(args: argparse.Namespace) -> int:
    h = _caps_hash(args.agent_path)
    if h is None:
        print(f"[!] {_caps_path(args.agent_path)} not found.", file=sys.stderr)
        return 1
    print(h)
    return 0


def cmd_drift(args: argparse.Namespace) -> int:
    """Compare current capabilities hash to drift.capability_hash_at_rbac.

    Exit codes:
      0 — no drift (or no baseline yet to compare against)
      1 — drift detected
      2 — capabilities file or status file missing
    """
    current = _caps_hash(args.agent_path)
    if current is None:
        print(f"[!] {_caps_path(args.agent_path)} not found.", file=sys.stderr)
        return 2
    try:
        data = _load(args.agent_path)
    except FileNotFoundError:
        print("[!] No agent-status.json yet — nothing to drift against.", file=sys.stderr)
        return 0  # not an error: first run

    baseline = _get_path(data, "drift.capability_hash_at_rbac")
    if not baseline:
        # Earlier baseline if RBAC not yet run
        baseline = _get_path(data, "drift.capability_hash_at_preflight")
    if not baseline:
        print(f"[i] No baseline hash recorded yet. Current: {current}")
        # Stamp it so next call has a baseline.
        _set_path(data, "drift.capability_hash_at_preflight", current)
        _set_path(data, "drift.drift_detected", False)
        _set_path(data, "drift.drift_fields", [])
        _save(args.agent_path, data)
        return 0

    if current == baseline:
        print(f"[+] No drift. capability hash = {current}")
        # Refresh the verify-side hash so the next run can detect post-verify edits.
        _set_path(data, "drift.capability_hash_at_verify", current)
        _set_path(data, "drift.drift_detected", False)
        _save(args.agent_path, data)
        return 0

    # Drift! Compute a coarse field-level diff (top-level YAML keys that changed).
    fields = _diff_top_level_keys(args.agent_path)
    print(f"[!] DRIFT detected.")
    print(f"    baseline: {baseline}")
    print(f"    current:  {current}")
    if fields:
        print(f"    changed top-level capability keys: {', '.join(fields)}")
    print("    Re-run /prepare-deploy and /configure-rbac before relying on /verify-agent.")
    _set_path(data, "drift.capability_hash_at_verify", current)
    _set_path(data, "drift.drift_detected", True)
    _set_path(data, "drift.drift_fields", fields)
    _save(args.agent_path, data)
    return 1


def _diff_top_level_keys(agent_path: str) -> list[str]:
    """Best-effort: list top-level capability keys that look different from the
    last committed version (uses git diff). Returns [] if git or HEAD blob is unavailable."""
    import subprocess
    try:
        diff = subprocess.check_output(
            ["git", "diff", "HEAD", "--", str(_caps_path(agent_path))],
            stderr=subprocess.DEVNULL, text=True, timeout=5,
        )
    except Exception:
        return []
    keys: list[str] = []
    for line in diff.splitlines():
        # Only consider added/removed lines that look like top-level YAML keys
        # under `capabilities:` (2-space indent).
        if line.startswith(("+  ", "-  ")) and ":" in line:
            stripped = line[3:].split(":", 1)[0].strip()
            if stripped and not stripped.startswith("-") and stripped not in keys:
                keys.append(stripped)
    return keys


# ── argparse wiring ─────────────────────────────────────────────────────────

def main() -> int:
    p = argparse.ArgumentParser(prog="agent_status.py", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("init", help="Create the file if absent.")
    sp.add_argument("--agent-path", required=True)
    sp.add_argument("--agent-name", required=True)
    sp.add_argument("--agent-kind", default="hosted", choices=["hosted", "prompt"])
    sp.set_defaults(func=cmd_init)

    sp = sub.add_parser("read", help="Print the file or a dotted field.")
    sp.add_argument("--agent-path", required=True)
    sp.add_argument("--field", default=None, help="Dotted path, e.g. rbac.capability_grants")
    sp.set_defaults(func=cmd_read)

    sp = sub.add_parser("update", help="Merge a section or set a path.")
    sp.add_argument("--agent-path", required=True)
    sp.add_argument("--section", default=None, choices=sorted(ALLOWED_SECTIONS))
    sp.add_argument("--path",    default=None, help="Dotted path (must start with an allowed section).")
    sp.add_argument("--json",    required=True, help="JSON value (object for --section, any JSON for --path)")
    sp.set_defaults(func=cmd_update)

    sp = sub.add_parser("hash", help="Print sha256:12 of agent-capabilities.yaml")
    sp.add_argument("--agent-path", required=True)
    sp.set_defaults(func=cmd_hash)

    sp = sub.add_parser("drift", help="Detect capability drift vs last RBAC baseline.")
    sp.add_argument("--agent-path", required=True)
    sp.set_defaults(func=cmd_drift)

    args = p.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
