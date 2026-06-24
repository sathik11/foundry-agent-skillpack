#!/usr/bin/env python3
"""Deterministic unit tests for the W3 guarded-driver guardrails (no network / no CLI).

Validates the loop-detector + event-parsing logic against synthetic opencode AND codex events,
so the anti-loop guarantee does not depend on provoking an LLM to misbehave.

Run: python tests/e2e/driver/test_guardrails.py
"""
import sys
from collections import deque
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import backends


def simulate(backend, events, loop_threshold=4):
    recent = deque(maxlen=loop_threshold)
    counts: dict[str, int] = {}
    for ev in events:
        kind, text = backend.parse(ev)
        if kind == "command":
            recent.append(text)
            counts[text] = counts.get(text, 0) + 1
            if counts[text] >= loop_threshold:
                return "looped", f"repeat {counts[text]}x"
            if len(recent) == recent.maxlen and len(set(recent)) <= 2:
                return "looped", "oscillating"
    return "completed", "ok"


def oc_cmd(c):
    return {"type": "tool_use", "part": {"tool": "bash", "state": {"input": {"command": c}}}}


def oc_msg(t):
    return {"type": "text", "part": {"text": t}}


def cx_cmd(c):
    return {"type": "item.completed", "item": {"type": "command_execution", "command": c}}


def cx_msg(t):
    return {"type": "item.completed", "item": {"type": "agent_message", "text": t}}


def main() -> int:
    oc = backends._BACKENDS["opencode"]
    cx = backends._BACKENDS["codex"]
    cases = [
        ("opencode identical-repeat", oc, [oc_cmd("az foo")] * 4, "looped"),
        ("opencode oscillation", oc, [oc_cmd("a"), oc_cmd("b"), oc_cmd("a"), oc_cmd("b")], "looped"),
        ("opencode distinct-ok", oc, [oc_cmd(x) for x in "abcde"], "completed"),
        ("opencode messages-ignored", oc, [oc_msg("hi")] * 10, "completed"),
        ("codex identical-repeat", cx, [cx_cmd("az foo")] * 4, "looped"),
        ("codex distinct-ok", cx, [cx_cmd(x) for x in "abcde"], "completed"),
        ("codex messages-ignored", cx, [cx_msg("hi")] * 10, "completed"),
    ]
    # parse correctness
    assert oc.parse(oc_cmd("az x")) == ("command", "az x")
    assert oc.parse(oc_msg("hello")) == ("message", "hello")
    assert cx.parse(cx_cmd("az y")) == ("command", "az y")
    assert cx.parse(cx_msg("hey")) == ("message", "hey")

    failed = 0
    for name, backend, events, expect in cases:
        got = simulate(backend, events)[0]
        ok = got == expect
        failed += not ok
        print(f"[{'ok' if ok else 'FAIL'}] {name}: expected {expect}, got {got}")
    if failed:
        print(f"\n{failed} test(s) FAILED")
        return 1
    print("\nAll guardrail tests passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
