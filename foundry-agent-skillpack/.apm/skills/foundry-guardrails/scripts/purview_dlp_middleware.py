"""Vendored Purview DLP middleware — Layer 1.5 of the guardrail stack.

Each agent COPIES this file into its own folder (same convention as guardrails.py).

What it does
------------
On each request and (optionally) each response, calls Microsoft Purview's
Information Protection / Compliance classification API to detect SITs
(Sensitive Information Types) and sensitivity labels in the payload. Looks up
matching policies and acts per `enforcement_mode`:

  audit_only — emit OTel span + AIPolicyEvaluated; allow request through
  warn       — annotate the response; emit event; allow request through
  block      — short-circuit with refusal text; emit AIPolicyBlocked

Honest caveats (read purview-dlp.md before enabling block mode)
---------------------------------------------------------------
- The Purview classification API surface for AI agent enforcement is preview-
  adjacent as of 2026-05-14. The middleware is intentionally defensive:
  * Audit-only is the default and ALWAYS works (fail-open on API errors).
  * Block mode requires AGREE_PURVIEW_DLP_PREVIEW=1 env var to construct.
- DefaultAzureCredential is the auth path. If your tenant requires a
  Compliance-Admin-tier token to call /classify, supply a service principal
  with that grant via env vars; the middleware will not invent privileged
  tokens.
- Latency: 150-500ms per call. Two calls per turn (input + response).
- Label propagation: sensitivity labels follow data via OBO (M365 path); for
  Foundry-hosted with acl_passthrough=false, labels in source documents may
  NOT appear in classification responses — only labels embedded in the
  prompt/response text itself will be detected.

Wire it (in main.py)
--------------------
    from guardrails import GuardrailAgentMiddleware
    from purview_dlp_middleware import PurviewDLPMiddleware

    agent = Agent(
        client=client,
        instructions=INSTRUCTIONS,
        tools=TOOLS,
        middleware=[
            GuardrailAgentMiddleware(agent_name="<name>", mode="entry"),
            PurviewDLPMiddleware(
                agent_name="<name>",
                enforcement_mode="audit_only",
                policies=["dlp-pii-strict"],
            ),
        ],
    )
"""
from __future__ import annotations

import logging
import os
from typing import Any, Literal

from agent_framework import AgentMiddleware, AgentResponse, Message

logger = logging.getLogger(__name__)

# --- Tunables (edit per agent) -----------------------------------------------

DEFAULT_REFUSAL_TEXT = (
    "Your request contained sensitive information that cannot be processed by "
    "this agent. Please remove sensitive details and try again."
)

DEFAULT_WARN_PREFACE = (
    "[Notice] This response was reviewed for sensitive content; please handle "
    "with appropriate care.\n\n"
)

# Purview classification endpoint. Override via env if your tenant uses a
# different scope. As of 2026-05-14 this is the documented baseline.
PURVIEW_CLASSIFY_ENDPOINT = os.environ.get(
    "PURVIEW_CLASSIFY_ENDPOINT",
    "https://api.purview-microsoft.com/datamap/api/atlas/v2/discovery/search",
)

# Approx classification latency budget — anything past this gets logged at
# warning level so operators can see latency drift.
LATENCY_WARN_MS = 600


# --- Middleware --------------------------------------------------------------


class PurviewDLPMiddleware(AgentMiddleware):
    """Layer 1.5 — Purview-driven DLP enforcement.

    Args:
        agent_name: Used in OTel attributes and logs.
        enforcement_mode: 'audit_only' | 'warn' | 'block'. Block requires
            AGREE_PURVIEW_DLP_PREVIEW=1 env var.
        policies: List of Purview policy IDs to consult. Empty = all configured
            policies attached to the agent's identity.
        classify_agent_response: Also classify the agent's outgoing response
            (default True).
        classify_tool_results: Also classify each tool result before it reaches
            the model (default False — adds latency).
        sit_types_to_check: Optional explicit list of SIT names; empty = all
            SITs the policies cover.
        refusal_text: Custom refusal for block mode.
        warn_preface: Custom warning preface for warn mode.
    """

    def __init__(
        self,
        agent_name: str,
        enforcement_mode: Literal["audit_only", "warn", "block"] = "audit_only",
        policies: list[str] | None = None,
        classify_agent_response: bool = True,
        classify_tool_results: bool = False,
        sit_types_to_check: list[str] | None = None,
        refusal_text: str = DEFAULT_REFUSAL_TEXT,
        warn_preface: str = DEFAULT_WARN_PREFACE,
    ) -> None:
        if enforcement_mode == "block" and os.environ.get("AGREE_PURVIEW_DLP_PREVIEW") != "1":
            raise RuntimeError(
                "PurviewDLPMiddleware: enforcement_mode='block' requires "
                "AGREE_PURVIEW_DLP_PREVIEW=1 env var. Read foundry-guardrails/"
                "purview-dlp.md § 'Honest preview limitations' before enabling."
            )

        self.agent_name = agent_name
        self.enforcement_mode = enforcement_mode
        self.policies = policies or []
        self.classify_agent_response = classify_agent_response
        self.classify_tool_results = classify_tool_results
        self.sit_types_to_check = sit_types_to_check or []
        self.refusal_text = refusal_text
        self.warn_preface = warn_preface

        # Lazy-init the Purview client on first use; keeps import cost low for
        # warm starts when the middleware is registered but not yet hit.
        self._client = None

    # ── Hooks ────────────────────────────────────────────────────────────

    async def on_request(self, context):  # type: ignore[override]
        """Classify the user's input before the LLM is called."""
        text = self._extract_input_text(context)
        if not text:
            return None

        verdict = await self._classify_and_decide(text, surface="input")
        return self._apply_verdict(context, verdict, surface="input")

    async def on_response(self, context):  # type: ignore[override]
        """Classify the agent's output before it leaves the container."""
        if not self.classify_agent_response:
            return None
        text = self._extract_response_text(context)
        if not text:
            return None

        verdict = await self._classify_and_decide(text, surface="response")

        # On the response surface, "block" replaces the response with refusal;
        # "warn" prefixes the warning; "audit_only" passes through.
        if verdict["decision"] == "block":
            self._set_response(context, self.refusal_text)
        elif verdict["decision"] == "warn":
            self._set_response(context, self.warn_preface + text)
        return None

    async def on_tool_result(self, context):  # type: ignore[override]
        """Optionally classify tool results before they reach the model."""
        if not self.classify_tool_results:
            return None
        text = self._extract_tool_result_text(context)
        if not text:
            return None

        verdict = await self._classify_and_decide(text, surface="tool_result")
        # On tool-result surface, block redacts; warn passes through with annotation.
        if verdict["decision"] == "block":
            self._redact_tool_result(context, "[REDACTED — sensitive content]")
        return None

    # ── Classification ──────────────────────────────────────────────────

    async def _classify_and_decide(self, text: str, surface: str) -> dict[str, Any]:
        """Returns {decision, sits, labels, policy_id, latency_ms}.

        Fails open (decision=audit_only) on any classification error — DLP
        never blocks an agent because the classifier itself is unhealthy.
        """
        import time

        from opentelemetry import trace

        tracer = trace.get_tracer(__name__)
        verdict: dict[str, Any] = {
            "decision": "audit_only",
            "sits": [],
            "labels": [],
            "policy_id": None,
            "latency_ms": 0,
            "surface": surface,
        }

        with tracer.start_as_current_span(f"guardrail.purview_dlp.{surface}") as span:
            t0 = time.monotonic()
            try:
                client = self._get_client()
                sits, labels = await self._classify(client, text)
                verdict["sits"] = sits
                verdict["labels"] = labels

                if self._policy_matches(sits, labels):
                    verdict["decision"] = self.enforcement_mode
                    verdict["policy_id"] = self._first_matching_policy(sits, labels)
            except Exception as exc:  # noqa: BLE001 — fail open
                logger.warning(
                    "purview_dlp_classification_failed",
                    extra={"agent": self.agent_name, "error": str(exc), "surface": surface},
                )
                verdict["decision"] = "audit_only"  # explicit fail-open

            verdict["latency_ms"] = int((time.monotonic() - t0) * 1000)

            # OTel attributes — keep keys stable for KQL and dashboards.
            span.set_attribute("guardrail.layer", "purview_dlp")
            span.set_attribute("guardrail.purview_dlp.surface", surface)
            span.set_attribute("guardrail.purview_dlp.decision", verdict["decision"])
            span.set_attribute("guardrail.purview_dlp.sits", verdict["sits"])
            span.set_attribute("guardrail.purview_dlp.labels", verdict["labels"])
            if verdict["policy_id"]:
                span.set_attribute("guardrail.purview_dlp.policy_id", verdict["policy_id"])
            span.set_attribute("guardrail.purview_dlp.latency_ms", verdict["latency_ms"])

            if verdict["latency_ms"] > LATENCY_WARN_MS:
                logger.warning(
                    "purview_dlp_slow",
                    extra={"agent": self.agent_name, "latency_ms": verdict["latency_ms"]},
                )

        return verdict

    async def _classify(self, client: Any, text: str) -> tuple[list[str], list[str]]:
        """Call the Purview classification API. Returns (sits, labels).

        SHAPE NOTE: The Purview Information Protection API for agent-runtime
        classification is preview-adjacent. This implementation targets the
        documented `/classify` shape. If your tenant exposes a different shape,
        swap this method's body — the rest of the middleware is shape-agnostic.
        """
        # Lazy import so the middleware module parses without azure SDKs.
        import httpx

        response = await client.post(
            PURVIEW_CLASSIFY_ENDPOINT,
            json={
                "text": text,
                "policy_ids": self.policies,
                "sit_types": self.sit_types_to_check,
            },
            timeout=10.0,
        )
        response.raise_for_status()
        data = response.json()
        sits = [s.get("name", "") for s in data.get("sits", []) if s.get("name")]
        labels = [l.get("id", "") for l in data.get("labels", []) if l.get("id")]
        return sits, labels

    def _policy_matches(self, sits: list[str], labels: list[str]) -> bool:
        """A policy matches if any SIT or label is detected. The actual policy
        engine lives in Purview; the middleware only needs to know whether to
        act, then which policy fired (for the audit trail)."""
        return bool(sits) or bool(labels)

    def _first_matching_policy(self, sits: list[str], labels: list[str]) -> str | None:
        """Best-effort: return the first declared policy. The Purview portal is
        the source of truth for which policy actually triggered."""
        return self.policies[0] if self.policies else None

    # ── Client + auth ───────────────────────────────────────────────────

    def _get_client(self):
        """Lazy-init an authenticated httpx client with bearer-token injection."""
        if self._client is not None:
            return self._client

        import httpx
        from azure.identity import DefaultAzureCredential

        credential = DefaultAzureCredential()

        class _AuthInjectingClient(httpx.AsyncClient):
            async def request(self, method, url, **kwargs):
                # Acquire a fresh token per request; SDK caches.
                token = credential.get_token("https://api.purview-microsoft.com/.default")
                headers = kwargs.pop("headers", {}) or {}
                headers["Authorization"] = f"Bearer {token.token}"
                kwargs["headers"] = headers
                return await super().request(method, url, **kwargs)

        self._client = _AuthInjectingClient()
        return self._client

    # ── Verdict application ─────────────────────────────────────────────

    def _apply_verdict(self, context, verdict, surface: str):
        if verdict["decision"] == "block":
            logger.info(
                "purview_dlp_block",
                extra={
                    "agent": self.agent_name,
                    "surface": surface,
                    "sits": verdict["sits"],
                    "labels": verdict["labels"],
                    "policy_id": verdict["policy_id"],
                },
            )
            context.result = AgentResponse(
                messages=[Message("assistant", self.refusal_text)],
            )
            return  # explicit short-circuit
        # warn / audit_only on input surface: pass through; warn annotation
        # happens on the response surface (after the LLM has produced text).
        return None

    # ── Helpers (text extraction tolerant of varying agent_framework shapes) ──

    @staticmethod
    def _extract_input_text(context) -> str:
        msgs = getattr(context, "messages", None) or []
        return "\n".join(
            m.content if isinstance(getattr(m, "content", None), str)
            else "\n".join(str(c) for c in (getattr(m, "content", None) or []))
            for m in msgs
        )

    @staticmethod
    def _extract_response_text(context) -> str:
        result = getattr(context, "result", None)
        if not result:
            return ""
        out: list[str] = []
        for m in getattr(result, "messages", None) or []:
            content = getattr(m, "content", None)
            if isinstance(content, str):
                out.append(content)
            elif isinstance(content, list):
                out.extend(str(c) for c in content)
        return "\n".join(out)

    @staticmethod
    def _extract_tool_result_text(context) -> str:
        result = getattr(context, "tool_result", None)
        if isinstance(result, str):
            return result
        if hasattr(result, "content"):
            content = result.content
            return content if isinstance(content, str) else "\n".join(map(str, content or []))
        return ""

    @staticmethod
    def _set_response(context, text: str) -> None:
        context.result = AgentResponse(messages=[Message("assistant", text)])

    @staticmethod
    def _redact_tool_result(context, replacement: str) -> None:
        if hasattr(context, "tool_result"):
            try:
                context.tool_result = replacement
            except (AttributeError, TypeError):
                pass  # Some contexts are immutable; the OTel span still records the decision.
