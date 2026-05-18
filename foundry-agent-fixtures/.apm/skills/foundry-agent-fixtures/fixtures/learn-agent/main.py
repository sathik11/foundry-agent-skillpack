"""Foundry hosted agent: learn-agent.

A minimal hosted agent whose only tool is the Microsoft Learn MCP server.
Pattern 1a (hosted + custom tools) with an external MCP attached via
FoundryChatClient.get_mcp_tool(...).
"""
import os

from agent_framework import Agent
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential

INSTRUCTIONS = """You are a Microsoft Learn assistant.

When the user asks a question about Microsoft, Azure, .NET, Power Platform,
M365, or any Microsoft product, use the `ms-learn` MCP tool to search the
official Microsoft Learn documentation and ground your answer in the results.

Rules:
- Always cite the Learn page URL(s) you used at the end of your reply.
- If the Learn search returns nothing relevant, say so plainly. Do not invent.
- Keep answers under 200 words unless the user asks for more.
"""


def build_agent() -> Agent:
    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["MODEL_DEPLOYMENT_NAME"],
        credential=DefaultAzureCredential(),
    )

    learn_mcp = client.get_mcp_tool(
        name="ms-learn",
        url="https://learn.microsoft.com/api/mcp",
        approval_mode="never_require",
    )

    return Agent(
        client=client,
        name="learn-agent",
        instructions=INSTRUCTIONS,
        tools=[learn_mcp],
        default_options={"store": False},
    )


if __name__ == "__main__":
    ResponsesHostServer(build_agent()).run()
