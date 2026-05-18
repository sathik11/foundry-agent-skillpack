# Entra Agent ID + Agent 365

(GA April 2026 — applies to all newly-created Foundry hosted agents.)

## Four Entra objects per agent

```
Blueprint  →  Blueprint Principal  →  Agent Identity (per-agent)  →  Agent User (optional)
```

The **per-agent identity** referenced throughout the RBAC matrix is the same object Entra classifies as `agent`-subtype Service Principal.

## Required admin steps

1. **Deploy agent** (`azd up`) → platform auto-creates per-agent identity.
2. **Apply RBAC** matrix → see [rbac-matrix.md](rbac-matrix.md).
3. **M365 admin** → Agents → All agents → assign sponsor to the agent.
4. **Entra admin** → Agent identities → confirm `agent`-subtype SP appears.

Post-deploy steps 3 & 4 are **manual** — there is no Graph API today (TD-2 in [/foundry-agent-skillpack/TECHNICAL_DEBT.md](../../../TECHNICAL_DEBT.md)).

## Directory roles (for admins managing agents)

| Role | What it can do |
|---|---|
| `AI Administrator` | Configure Foundry-wide policies, assign sponsors |
| `Agent ID Administrator` | Create/disable agent identities |
| `Agent ID Developer` | Create new agent identities (deploy) |

## Conditional Access for agents

Agent 365 enables CA policies targeting agent identities:
- **Location-based:** block agent runs from non-corp networks
- **Risk-based:** require sponsor approval before action
- **Lifecycle:** time-box identity existence (auto-disable after N days)
- **Emergency:** disable agent identity (NOT blueprint) — kills runs without breaking deploys

Agent identities show up in CA policy target picker as "Service Principals" with subtype `agent`.

## See also

- Inventory check (Graph beta) → [foundry-teams-workiq](../foundry-teams-workiq/SKILL.md) "Verification" section.
