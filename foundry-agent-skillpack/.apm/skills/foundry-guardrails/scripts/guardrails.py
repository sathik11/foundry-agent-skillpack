"""
Vendored guardrail middleware for Foundry hosted agents.

Each agent COPIES this file into its own folder (no shared import — build
context is the agent folder). Tune `BLOCKED_PATTERNS`, `XPIA_TOKENS`, and
`REFUSAL_TEXT` per agent.

Usage in main.py:
    from guardrails import GuardrailAgentMiddleware
    agent = Agent(
        client=client,
        instructions=INSTRUCTIONS,
        tools=TOOLS,
        middleware=[GuardrailAgentMiddleware(agent_name="my-agent", mode="entry")],
    )
"""
from __future__ import annotations

import logging
import os
import re
from typing import Literal

from agent_framework import AgentMiddleware, AgentResponse, Message

logger = logging.getLogger(__name__)

# --- Tunables (edit per agent) -----------------------------------------------

BLOCKED_PATTERNS = [
    re.compile(r"(?i)\bignore (all )?(previous|prior) instructions?\b"),
    re.compile(r"(?i)\b(you are|act as|pretend to be) (now |a )?(DAN|jailbroken|root|admin)\b"),
    re.compile(r"(?i)reveal( your)? (system|hidden) prompt"),
]

XPIA_TOKENS = [
    "<<SYSTEM>>",
    "<|im_start|>system",
    "[OVERRIDE]",
]

REFUSAL_TEXT = (
    "I can't help with that request. If you believe this was blocked in error, "
    "include more context about your task."
)

ENTRY_CHAR_CAP = 8_000
PAYLOAD_CHAR_CAP = 200_000

# --- Optional Layer 2 (Azure Content Safety) ---------------------------------

CS_ENDPOINT = os.environ.get("AZURE_CONTENT_SAFETY_ENDPOINT")
CS_THRESHOLD = int(os.environ.get("AZURE_CONTENT_SAFETY_THRESHOLD", "4"))


def _check_content_safety(text: str) -> tuple[bool, str | None]:
    """Returns (passed, reason). Fails open if endpoint not configured."""
    if not CS_ENDPOINT:
        return True, "disabled"
    try:
        # Lazy import — keep dep optional
        from azure.ai.contentsafety import ContentSafetyClient
        from azure.ai.contentsafety.models import AnalyzeTextOptions
        from azure.identity import DefaultAzureCredential

        client = ContentSafetyClient(CS_ENDPOINT, DefaultAzureCredential())
        result = client.analyze_text(AnalyzeTextOptions(text=text))
        for cat in result.categories_analysis:
            if cat.severity >= CS_THRESHOLD:
                return False, f"content_safety:{cat.category}:{cat.severity}"
        return True, None
    except Exception as exc:  # noqa: BLE001 — fail open, log
        logger.warning("content_safety_call_failed", extra={"error": str(exc)})
        return True, "error_fail_open"


# --- Middleware --------------------------------------------------------------


class GuardrailAgentMiddleware(AgentMiddleware):
    def __init__(
        self,
        agent_name: str,
        mode: Literal["entry", "payload"] = "entry",
    ) -> None:
        self.agent_name = agent_name
        self.mode = mode
        self.cap = ENTRY_CHAR_CAP if mode == "entry" else PAYLOAD_CHAR_CAP

    async def on_request(self, context):  # type: ignore[override]
        text = self._extract_text(context)

        # 1. Length
        if len(text) > self.cap:
            return self._block(context, layer="length", reason=f"{len(text)}>{self.cap}")

        # 2. Jailbreak regex
        for pat in BLOCKED_PATTERNS:
            if pat.search(text):
                return self._block(context, layer="jailbreak", reason=pat.pattern)

        # 3. XPIA tokens
        for tok in XPIA_TOKENS:
            if tok in text:
                if self.mode == "entry":
                    return self._block(context, layer="xpia", reason=tok)
                logger.info("xpia_flag_payload_mode", extra={"token": tok})

        # 4. Content Safety (entry mode only)
        if self.mode == "entry":
            passed, reason = _check_content_safety(text)
            if not passed:
                return self._block(context, layer="content_safety", reason=reason or "")

        # Pass — continue to LLM
        return None

    # --- helpers ---------------------------------------------------------

    @staticmethod
    def _extract_text(context) -> str:
        msgs = getattr(context, "messages", None) or []
        parts: list[str] = []
        for m in msgs:
            content = getattr(m, "content", None)
            if isinstance(content, str):
                parts.append(content)
            elif isinstance(content, list):
                parts.extend(str(c) for c in content)
        return "\n".join(parts)

    def _block(self, context, *, layer: str, reason: str):
        logger.info(
            "guardrail_block",
            extra={
                "agent": self.agent_name,
                "guardrail.layer": layer,
                "guardrail.reason": reason,
                "guardrail.mode": self.mode,
            },
        )
        context.result = AgentResponse(messages=[Message("assistant", REFUSAL_TEXT)])
        return  # explicit short-circuit
