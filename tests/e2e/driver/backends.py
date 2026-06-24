"""backends.py — pluggable driver backends for the W3 guarded runner.

Each backend wraps an agentic CLI that (a) runs headless, (b) emits JSONL events, (c) can
execute shell tools (az/azd/docker). run_driver.py is backend-agnostic; it only needs each
backend to provide:

  argv(prompt, workdir, model, full_access)  -> list[str]   # the CLI command to spawn
  parse(event: dict)                         -> ("command"|"message"|None, text)

DECISION (2026-06-24): default backend is **opencode** — model-agnostic (Anthropic / OSS /
Azure / OpenAI-compatible via models.dev), so the driver brain can later switch to Claude or an
OSS-weight model with a config edit, not a rewrite. **codex** is retained as an alternate backend.
Both were validated against the Foundry gpt-5.4 deployment using the Responses API + AAD token.
"""
from __future__ import annotations

import shutil


class Backend:
    name = "base"

    def argv(self, prompt: str, workdir: str, model: str, full_access: bool) -> list[str]:
        raise NotImplementedError

    def parse(self, ev: dict) -> tuple[str | None, str]:
        """Return (kind, text): kind in {'command','message',None}."""
        raise NotImplementedError


class OpenCodeBackend(Backend):
    name = "opencode"
    default_model = "foundry/gpt-5.4"

    def argv(self, prompt, workdir, model, full_access):
        # --format json → raw JSONL events; --dir → workdir. opencode runs tools by default.
        return ["opencode", "run", "--format", "json", "--dir", workdir,
                "--model", model, prompt]

    def parse(self, ev):
        t = ev.get("type")
        if t == "tool_use":
            part = ev.get("part", {})
            if part.get("tool") == "bash":
                cmd = (part.get("state", {}).get("input", {}) or {}).get("command")
                if cmd:
                    return "command", cmd[:400]
        elif t == "text":
            txt = ev.get("part", {}).get("text") or ev.get("text") or ""
            if txt:
                return "message", txt
        return None, ""


class CodexBackend(Backend):
    name = "codex"
    default_model = "gpt-5.4"

    def argv(self, prompt, workdir, model, full_access):
        argv = ["codex", "exec", "--json", "--skip-git-repo-check", "-C", workdir, "--model", model]
        argv += (["--dangerously-bypass-approvals-and-sandbox"] if full_access
                 else ["--sandbox", "workspace-write"])
        argv += [prompt]
        return argv

    def parse(self, ev):
        if ev.get("type") == "item.completed":
            item = ev.get("item", {})
            it = item.get("type")
            if it == "agent_message":
                return "message", item.get("text", "")
            if it in ("command_execution", "local_shell_call", "exec_command"):
                cmd = item.get("command") or item.get("text") or ""
                if cmd:
                    return "command", cmd[:400]
        return None, ""


_BACKENDS = {b.name: b for b in (OpenCodeBackend(), CodexBackend())}


def get(name: str) -> Backend:
    if name not in _BACKENDS:
        raise SystemExit(f"unknown backend {name!r}; choices: {', '.join(_BACKENDS)}")
    b = _BACKENDS[name]
    if not shutil.which(b.name):
        raise SystemExit(f"[!] {b.name} CLI not found on PATH")
    return b


def default_model_for(name: str) -> str:
    return _BACKENDS[name].default_model
