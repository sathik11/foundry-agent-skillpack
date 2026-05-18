# Layer 1 — Vendored Middleware

Sub-millisecond, in-process. First line of defense before the LLM is touched.

## Wire it

```python
from guardrails import GuardrailAgentMiddleware

agent = Agent(
    client=client,
    instructions=INSTRUCTIONS,
    tools=TOOLS,
    middleware=[GuardrailAgentMiddleware(agent_name="<name>-v3", mode="entry")],
)
```

The middleware module ships in [scripts/guardrails.py](scripts/guardrails.py). Each agent vendors its own copy (different constructor args, different blocked-token sets).

## Modes

| Mode | When | Cap | Behavior |
|---|---|---|---|
| `entry` | Edge agents (user prompts) | 8K chars | Jailbreak regex, XPIA, length, Content Safety |
| `payload` | Pipeline agents (JSON payloads) | 200K chars | XPIA flag-only (log, don't block); skip CS |

## Short-circuit pattern (in middleware)

```python
context.result = AgentResponse(
    messages=[Message("assistant", [blocked_text])],
)
return  # LLM is never called
```

## What it catches

- Length explosions (`> cap` chars)
- Known jailbreak prefixes (vendored regex set)
- Indirect prompt-injection (XPIA) tokens in tool results
- Optional Layer-2 cascade if `AZURE_CONTENT_SAFETY_ENDPOINT` is set
