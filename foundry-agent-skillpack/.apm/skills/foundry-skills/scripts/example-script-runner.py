"""Reference script runner for agent-framework SkillsProvider.

Copy + adapt into the agent's main.py (or a sibling module). This is the
canonical safe pattern documented in foundry-skills/SKILL.md — the script
runner is the security boundary, not SkillsProvider itself.

Hard rules enforced here:
  - Script path must resolve inside the skill directory (path-traversal guard).
  - 60-second wall-clock timeout.
  - capture_output=True; no inheritance of stdin/stdout/stderr.
  - subprocess argv-style call; no shell=True.
  - Booleans become bare flags (--flag) with no value.
  - Lists become comma-joined strings.
  - Dicts become JSON.

Pair this with an OTel span around the subprocess call (see SKILL.md "OTel and
verification") so verify-agent KQL can see skill execution.

Origin: matches the pattern in foundry-samples sample 07
(samples/python/hosted-agents/agent-framework/responses/07-skills/main.py).
"""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

# Optional: OTel for observability. Comment out if instrumentation isn't wired.
try:
    from opentelemetry import trace
    _tracer = trace.get_tracer(__name__)
except ImportError:
    _tracer = None


def run_local_skill_script(skill: Any, script: Any, args: dict[str, Any] | None = None) -> str:
    """Execute a file-based skill script with simple CLI arguments.

    `skill` and `script` are agent_framework Skill / SkillScript objects. Their
    `.path` attribute is the source-of-truth filesystem location.
    """
    if skill.path is None or script.path is None:
        return "Error: only file-based skill scripts can be run by this runner."

    # Path-traversal guard: resolved script path must be inside the skill dir.
    skill_path = Path(skill.path).resolve()
    script_path = (skill_path / script.path).resolve()
    if skill_path != script_path and skill_path not in script_path.parents:
        return f"Error: script '{script.path}' resolves outside the skill directory."

    # Build argv. No shell=True. CLI args only.
    command = [sys.executable, str(script_path)]
    for key, value in (args or {}).items():
        if value is None:
            continue
        option = f"--{key.replace('_', '-')}"

        # Booleans become bare flags.
        if isinstance(value, bool):
            if value:
                command.append(option)
            continue

        # Lists / tuples join with commas; dicts become JSON.
        if isinstance(value, (list, tuple)):
            value = ",".join(str(item) for item in value)
        elif isinstance(value, dict):
            value = json.dumps(value)

        command.extend([option, str(value)])

    span_ctx = (
        _tracer.start_as_current_span(f"skill.{skill.name}.{script.path}")
        if _tracer is not None else _NullSpan()
    )

    with span_ctx as span:
        if _tracer is not None and span is not None:
            span.set_attribute("skill.name",       skill.name)
            span.set_attribute("skill.script",     script.path)
            span.set_attribute("skill.args_count", len(args or {}))

        try:
            completed = subprocess.run(
                command,
                cwd=skill_path,
                capture_output=True,
                check=False,
                text=True,
                timeout=60,
            )
        except subprocess.TimeoutExpired:
            if _tracer is not None and span is not None:
                span.set_attribute("skill.exit_code", -1)
            return f"Error: script '{script.path}' timed out after 60 seconds."

        if _tracer is not None and span is not None:
            span.set_attribute("skill.exit_code", completed.returncode)

    stdout = completed.stdout.strip()
    stderr = completed.stderr.strip()
    if completed.returncode != 0:
        details = stderr or stdout or "no error output was produced."
        return f"Error: script '{script.path}' failed with exit code {completed.returncode}: {details}"

    return stdout or f"Script '{script.path}' completed successfully."


class _NullSpan:
    """Fallback context manager when OTel isn't installed."""
    def __enter__(self):
        return None
    def __exit__(self, *_):
        return False
