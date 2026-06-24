#!/usr/bin/env python3
"""run_driver.py — W3 guarded driver: drive an agentic CLI (opencode by default, codex alt) the
way a real user would run the skillpack /commands, with hard anti-loop / anti-stall guardrails.

This is the "human surrogate". It does NOT decide scenario pass/fail (the W4 smoke harness asserts
on agent-status.json) — it produces a DRIVER verdict about HOW the run went:

  completed   the CLI finished a turn cleanly (exit 0)
  failed      the CLI exited non-zero
  timeout     wall-clock budget exceeded
  stalled     no new event for --no-progress seconds (watchdog) and nothing in flight
  looped      the same shell command repeated >= --loop-threshold times (oscillation)

Guardrails (the maintainer's "agent goes in loops / loses track" problem):
  * wall-clock timeout (total)
  * no-progress watchdog (generous, so a long Azure op like `azd up` is NOT a false stall)
  * loop detector on repeated identical command executions
  * full structured transcript + verdict JSON for human review

Backend is pluggable (see backends.py): --backend opencode|codex. Default opencode for model
flexibility (Anthropic/OSS/Azure via models.dev).

Usage:
  run_driver.py --prompt-file scenario.md --workdir /path/to/agent/repo \
      --artifacts tests/e2e/artifacts/<run-id> [--backend opencode] [--model foundry/gpt-5.4]

Auth: needs a fresh AAD token. opencode reads it from its config apiKey (refresh via
configure-opencode.sh); codex reads FOUNDRY_API_KEY. This script ensures FOUNDRY_API_KEY is set.
"""
from __future__ import annotations

import argparse
import json
import os
import queue
import subprocess
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backends  # noqa: E402

SCOPE = "https://cognitiveservices.azure.com/.default"


def ensure_token() -> str:
    tok = os.environ.get("FOUNDRY_API_KEY")
    if tok:
        return tok
    out = subprocess.check_output(
        ["az", "account", "get-access-token", "--scope", SCOPE, "--query", "accessToken", "-o", "tsv"],
        text=True,
    ).strip()
    os.environ["FOUNDRY_API_KEY"] = out
    return out


def reader_thread(stream, q: "queue.Queue") -> None:
    for line in iter(stream.readline, ""):
        q.put(line)
    stream.close()
    q.put(None)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--prompt-file")
    ap.add_argument("--prompt")
    ap.add_argument("--workdir", default=".")
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--backend", default="opencode", choices=["opencode", "codex"])
    ap.add_argument("--model", default=None, help="provider/model (defaults per backend)")
    ap.add_argument("--agent", default=None, help="backend agent persona (opencode --agent)")
    ap.add_argument("--wall-clock", type=int, default=2400, help="total budget seconds (default 40m)")
    ap.add_argument("--no-progress", type=int, default=1200,
                    help="kill if no event for this long (default 20m; > longest single Azure op on a WARM baseline)")
    ap.add_argument("--loop-threshold", type=int, default=4,
                    help="kill if an identical shell command repeats this many times")
    ap.add_argument("--full-access", action="store_true",
                    help="allow network + write (needed for az/azd). Implied in CI.")
    args = ap.parse_args()

    if args.prompt_file:
        prompt = Path(args.prompt_file).read_text()
    elif args.prompt:
        prompt = args.prompt
    else:
        print("[!] need --prompt or --prompt-file", file=sys.stderr)
        return 2

    backend = backends.get(args.backend)
    model = args.model or backends.default_model_for(args.backend)
    full_access = args.full_access or bool(os.environ.get("CI"))
    ensure_token()

    art = Path(args.artifacts)
    art.mkdir(parents=True, exist_ok=True)
    transcript = (art / "transcript.jsonl").open("w")

    cmd = backend.argv(prompt, args.workdir, model, full_access, agent=args.agent)
    started = time.time()
    # stdin=DEVNULL: the driver is always non-interactive. Without this, a detached/nohup launch
    # leaves the child with an invalid inherited stdin → opencode fails with "EBADF: bad file
    # descriptor, read" before emitting any event.
    proc = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, bufsize=1)
    q: "queue.Queue" = queue.Queue()
    threading.Thread(target=reader_thread, args=(proc.stdout, q), daemon=True).start()

    verdict, reason = "completed", "CLI finished a turn"
    last_event = time.time()
    last_message = ""
    recent_cmds: deque[str] = deque(maxlen=args.loop_threshold)
    cmd_counts: dict[str, int] = {}
    n_events = n_commands = 0

    def stop(v: str, r: str):
        nonlocal verdict, reason
        verdict, reason = v, r
        try:
            proc.terminate()
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                proc.kill()
        except Exception:
            pass

    while True:
        now = time.time()
        if now - started > args.wall_clock:
            stop("timeout", f"wall-clock budget {args.wall_clock}s exceeded")
            break
        if now - last_event > args.no_progress:
            stop("stalled", f"no event for {args.no_progress}s (watchdog)")
            break
        try:
            line = q.get(timeout=2)
        except queue.Empty:
            if proc.poll() is not None and q.empty():
                break
            continue
        if line is None:
            break
        last_event = time.time()
        transcript.write(line if line.endswith("\n") else line + "\n")
        transcript.flush()
        line = line.strip()
        if not line:
            continue
        try:
            ev = json.loads(line)
        except json.JSONDecodeError:
            continue
        n_events += 1
        kind, text = backend.parse(ev)
        if kind == "message":
            last_message = text
        elif kind == "command":
            n_commands += 1
            recent_cmds.append(text)
            cmd_counts[text] = cmd_counts.get(text, 0) + 1
            if cmd_counts[text] >= args.loop_threshold:
                stop("looped", f"command repeated {cmd_counts[text]}x: {text[:120]}")
                break
            if len(recent_cmds) == recent_cmds.maxlen and len(set(recent_cmds)) <= 2:
                stop("looped", f"oscillating between {len(set(recent_cmds))} commands")
                break

    rc = proc.poll()
    if verdict == "completed" and rc not in (0, None):
        verdict, reason = "failed", f"CLI exited rc={rc}"
    transcript.close()

    result = {
        "verdict": verdict,
        "reason": reason,
        "backend": args.backend,
        "model": model,
        "workdir": str(Path(args.workdir).resolve()),
        "duration_s": round(time.time() - started, 1),
        "events": n_events,
        "commands": n_commands,
        "last_message": last_message[-2000:],
        "exit_code": rc,
        "started_at": datetime.fromtimestamp(started, timezone.utc).isoformat(),
        "budgets": {"wall_clock": args.wall_clock, "no_progress": args.no_progress,
                    "loop_threshold": args.loop_threshold},
    }
    (art / "verdict.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0 if verdict == "completed" else 1


if __name__ == "__main__":
    sys.exit(main())
