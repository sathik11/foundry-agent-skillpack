---
name: foundry-identity
description: Two-identity model, RBAC matrix, Entra Agent ID, and Agent 365 governance overlay for Foundry agents
---

# Foundry Identity & RBAC — Router

| Topic | Read |
|---|---|
| Project MI vs per-agent identity (how to get them) | [two-identities.md](two-identities.md) |
| Full RBAC matrix (Phase 1/2/3) + capability-aware grants | [rbac-matrix.md](rbac-matrix.md) |
| Entra Agent ID, Agent 365, Conditional Access | [entra-agent-id.md](entra-agent-id.md) |
| Identity discovery script | [scripts/check-identities.sh](scripts/check-identities.sh) |
| Phase 1+2 grant script | [scripts/grant-rbac.sh](scripts/grant-rbac.sh) |

## One-line truths

- **Two identities.** Project MI pulls images. Per-agent SP runs the agent.
- **Per-agent identity does not exist pre-`azd up`.** Phase A records, Phase B executes.
- **Account scope is required**, not just project. Project-only grants → 403 on model calls.
- **5–15 min propagation** after every grant. Don't smoke-test immediately.
- **Capability-aware grants** (Fabric / CS / etc) are dispatched by `/configure-rbac` from the manifest.

## Cross-skill references

- Caller-side roles (this scope) vs agent-side identities (other scope) → [foundry-roles](../foundry-roles/SKILL.md)
- Capability manifest schema → [foundry-deploy/capabilities-manifest.md](../foundry-deploy/capabilities-manifest.md)
- Content Safety grant script → [foundry-guardrails/scripts/grant-cs-access.sh](../foundry-guardrails/scripts/grant-cs-access.sh)
- Fabric workspace role assignment → [foundry-fabric](../foundry-fabric/SKILL.md)
- Teams / Agent 365 manual steps → [foundry-teams-workiq](../foundry-teams-workiq/SKILL.md)
- Network operations roles (Phase 4) → [foundry-roles/role-matrix.md](../foundry-roles/role-matrix.md)

