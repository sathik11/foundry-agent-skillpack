---
title: Reference — Role matrix
description: Every action the skillpack performs, with required role and scope.
---

The full role matrix lives in the **foundry-roles** skill. This page is a quick reference; the source of truth is:

[**View the full role matrix on GitHub →**](https://github.com/sathik11/Foundry-Hosted-Agent-Skill/blob/main/foundry-agent-skillpack/.apm/skills/foundry-roles/role-matrix.md)

## Five phases at a glance

| Phase | What | Persona |
| --- | --- | --- |
| 0 | Read-only preflight | Caller (Reader floor) |
| 1 | Build & deploy | DevOps |
| 2 | Per-agent identity grants | DevOps |
| 3 | Eval / monitoring / red-team | DevOps |
| 4 | Network isolation | Network Admin |
| 5 | Tenant-scoped (Purview / Fabric / Teams / Entra) | Tenant Admin |

## Phase 0 — Preflight (Reader floor)

| Action | Role | Scope |
| --- | --- | --- |
| Read Foundry account / project metadata | `Reader` | account |
| Read source resource for network preflight | `Reader` | each declared resource |
| Read App Insights schema for KQL | `Reader` | App Insights |
| List ACR repositories | `Reader` + `AcrPull` | ACR |

If `Reader` is missing on a resource, the skillpack **does not stop** — it degrades the affected gate to a checklist and prints the runbook.

## Phase 1 — Build & deploy

| Action | Role | Scope |
| --- | --- | --- |
| `azd up` | `Contributor` | Foundry account RG |
| Push image to ACR (BYO build) | `AcrPush` or `Container Registry Repository Writer` | ACR |
| Pull image from ACR (Project MI; auto-assigned) | `AcrPull` or `Container Registry Repository Reader` | ACR |
| Create / edit Foundry connections | `Azure AI Project Manager` | project |
| Set environment variables | `Azure AI Developer` | project |

## Phase 2 — Per-agent identity grants

The caller granting these needs `Owner` or `User Access Administrator`.

| Grant target → role | Scope |
| --- | --- |
| Per-agent SP → `Azure AI User` | account (critical) + project |
| Per-agent SP → `Azure AI Developer` | project |
| Per-agent SP → `Cognitive Services OpenAI User` | account |
| Per-agent SP → `Cognitive Services User` | account |
| Per-agent SP → `Cognitive Services User` | Content Safety resource (when guardrails L2 declared) |
| Per-agent SP → `Search Index Data Reader` | AI Search resource |
| Per-agent SP → `Storage Blob Data Reader` | Storage account |
| Per-agent SP → `Cosmos DB Built-in Data Contributor` (`00000000-0000-0000-0000-000000000002`) | Cosmos account |

## Phase 3 — Eval / monitoring / red-team

| Action | Role | Scope |
| --- | --- | --- |
| Create / update continuous eval rule | `Azure AI User` | project |
| Create / update scheduled eval (preview) | `Azure AI User` | project |
| Create / schedule cloud red-team (preview) | `Azure AI User` | project + supported region |
| Configure Monitor dashboard alerts (preview) | `Azure AI User` + `Monitoring Contributor` | project + App Insights RG |
| Read continuous-eval results | `Reader` + `Log Analytics Reader` | App Insights + Log Analytics |

## Phase 4 — Network isolation

| Action | Role | Scope |
| --- | --- | --- |
| Create managed VNet on Foundry account | `Contributor` | Foundry account |
| Approve managed PE connection | `Azure AI Enterprise Network Connection Approver` (`b556d68e-0be0-4f35-a333-ad7ee1ce17ea`) | target resource |
| Approve PE on target resource | `Contributor` or `Owner` | target resource |
| Create delegated subnet for BYO VNet | `Network Contributor` | VNet + subnet |
| Link private DNS zone to VNet | `Network Contributor` | private DNS zone + VNet |

## Phase 5 — Tenant-scoped (almost always runbook)

| Action | Role | Scope |
| --- | --- | --- |
| Toggle Microsoft Purview integration | `Cognitive Services Security Integration Administrator` or `Azure AI Account Owner` | account |
| Create DSPM / DLP policies for AI | `Purview Data Security AI Admin` | tenant |
| Grant Purview DLP middleware roles | `Privileged Role Administrator` | tenant |
| Add per-agent identity to Fabric workspace | `Fabric Admin` (workspace) | Fabric workspace |
| Register agent in Agent 365 / Teams | `Teams Administrator` + `M365 Admin` | tenant |
| Create Entra app | `Application Administrator` | tenant |

## Action keyword lookup

`preflight-role.sh` accepts an action name as a synonym for the (role, scope) pair:

| Keyword | Resolves to |
| --- | --- |
| `deploy` | Phase 1, `Contributor` on account RG |
| `grant-rbac` | Phase 2, `Owner` or `User Access Administrator` on grant target |
| `setup-evals` | Phase 3, `Azure AI User` on project |
| `setup-redteam` | Phase 3, `Azure AI User` on project + region check |
| `network-preflight` | Phase 0, `Reader` on each declared resource |
| `audit-drift` | Phase 0, `Reader` on the project + each declared resource |
| `approve-pe` | Phase 4, `Azure AI Enterprise Network Connection Approver` on target |
| `purview-toggle` | Phase 5, `Cognitive Services Security Integration Administrator` on account |
| `fabric-workspace-add` | Phase 5, Fabric `Admin` on workspace |

## Read next

- [Personas and roles](/concepts/personas-and-roles/) — the runbook handoff pattern.
- [Reference: Scripts](/reference/scripts/) — `preflight-role.sh` + `runbook-emit.sh` + `list-my-roles.sh`.
