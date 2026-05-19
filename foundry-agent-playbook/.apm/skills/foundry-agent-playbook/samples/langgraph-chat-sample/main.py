"""langgraph-chat-fixture — clean LangGraph BYO hosted agent for smoke testing.

Mirrors the foundry-deploy/templates/langgraph-byo/main.py.template. Use this
fixture to validate end-to-end deployment of a LangGraph agent through the
foundry-agent-skillpack skillpack:

  /prepare-deploy → azd up → /configure-rbac → /verify-agent → /setup-evals

This fixture is INTENDED TO PASS every gate. It complements `learn-agent`,
which is intended to FAIL specific gates so you can see them fire.
"""
from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timezone
from typing import Annotated

from azure.ai.agentserver.responses import (
    CreateResponse,
    ResponseContext,
    ResponsesAgentServerHost,
    ResponsesServerOptions,
    TextResponse,
)
from azure.ai.agentserver.responses.models import (
    MessageContentInputTextContent,
    MessageContentOutputTextContent,
)
from azure.identity import DefaultAzureCredential
from langchain_azure_ai.chat_models import AzureAIOpenAIApiChatModel
from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.tools import tool
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode
from typing_extensions import TypedDict

logger = logging.getLogger(__name__)

if not os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING"):
    logger.warning(
        "APPLICATIONINSIGHTS_CONNECTION_STRING not set — local traces won't ship to App Insights. "
        "Auto-injected in hosted Foundry; never declare in agent.manifest.yaml."
    )

FOUNDRY_PROJECT_ENDPOINT = os.environ.get("FOUNDRY_PROJECT_ENDPOINT")
if not FOUNDRY_PROJECT_ENDPOINT:
    raise EnvironmentError("FOUNDRY_PROJECT_ENDPOINT not set.")

AZURE_AI_MODEL_DEPLOYMENT_NAME = os.environ.get("AZURE_AI_MODEL_DEPLOYMENT_NAME")
if not AZURE_AI_MODEL_DEPLOYMENT_NAME:
    raise EnvironmentError("AZURE_AI_MODEL_DEPLOYMENT_NAME not set.")


@tool
def get_current_time() -> str:
    """Return the current UTC date and time."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")


@tool
def calculator(expression: str) -> str:
    """Evaluate a simple math expression and return the result."""
    try:
        result = eval(expression, {"__builtins__": {}})  # noqa: S307 — sandbox-fixture only
        return str(result)
    except Exception as exc:
        return f"Error: {exc}"


TOOLS = [get_current_time, calculator]


class State(TypedDict):
    messages: Annotated[list, add_messages]


def _build_graph() -> StateGraph:
    llm = AzureAIOpenAIApiChatModel(
        project_endpoint=FOUNDRY_PROJECT_ENDPOINT,
        credential=DefaultAzureCredential(),
        model=AZURE_AI_MODEL_DEPLOYMENT_NAME,
        streaming=True,
    )
    llm_with_tools = llm.bind_tools(TOOLS)

    def chatbot(state: State):
        return {"messages": [llm_with_tools.invoke(state["messages"])]}

    def route_tools(state: State):
        last = state["messages"][-1]
        if hasattr(last, "tool_calls") and last.tool_calls:
            return "tools"
        return END

    graph = StateGraph(State)
    graph.add_node("chatbot", chatbot)
    graph.add_node("tools", ToolNode(tools=TOOLS))
    graph.add_edge(START, "chatbot")
    graph.add_conditional_edges("chatbot", route_tools, {"tools": "tools", END: END})
    graph.add_edge("tools", "chatbot")
    return graph.compile()


GRAPH = _build_graph()


def _history_to_langchain_messages(history: list) -> list:
    messages = []
    for item in history:
        if hasattr(item, "content") and item.content:
            for content in item.content:
                if isinstance(content, MessageContentOutputTextContent) and content.text:
                    messages.append(AIMessage(content=content.text))
                elif isinstance(content, MessageContentInputTextContent) and content.text:
                    messages.append(HumanMessage(content=content.text))
    return messages


app = ResponsesAgentServerHost(
    options=ResponsesServerOptions(default_fetch_history_count=20),
)


@app.response_handler
async def handle_create(
    request: CreateResponse,
    context: ResponseContext,
    cancellation_signal: asyncio.Event,
):
    async def run_graph():
        try:
            try:
                history = await context.get_history()
            except Exception:
                history = []
            current_input = await context.get_input_text() or "Hello!"
            lc_messages = _history_to_langchain_messages(history)
            lc_messages.append(HumanMessage(content=current_input))

            result = await GRAPH.ainvoke({"messages": lc_messages})
            raw = result["messages"][-1].content
            if isinstance(raw, list):
                yield "".join(
                    (block.get("text", "") if isinstance(block, dict) else str(block))
                    for block in raw
                )
            else:
                yield raw or ""
        except Exception as exc:
            logger.exception("run_graph failed")
            yield f"[ERROR] {type(exc).__name__}: {exc}"

    return TextResponse(context, request, text=run_graph())


if __name__ == "__main__":
    app.run()
