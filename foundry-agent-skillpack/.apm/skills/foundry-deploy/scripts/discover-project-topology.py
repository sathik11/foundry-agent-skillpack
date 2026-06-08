#!/usr/bin/env python3
"""Format the KEY=VALUE topology stream from discover-project-topology.sh into
three artifacts:

  * `project-topology.md`            — human-readable verdict report (✅/⚠/❌)
  * `project-topology.json`          — machine-readable equivalent (CI / `jq`)
  * `agent-capabilities.draft.yaml`  — pre-filled stub the user can edit

Used by `/assess-project` Step 2.

Read-only — does not mutate Azure. Reads stdin (KEY=VALUE per line) OR an
input file via --input.

Usage:
    discover-project-topology.sh <sub> <rg> | \\
        python3 discover-project-topology.py --out-dir ./assessment

Verdict rubric (single source of truth — referenced by docs concept page):

    ✅  Present and shaped as expected for hosted-agent workloads.
    ⚠  Present but with caveats the user should consider before deploying.
    ❌  Absent or wrong-shape — would cause a known failure if an agent ran today.

Verdicts are intentionally conservative. The script never says "you must" — it
flags gaps and points at the skillpack reference that explains the fix.
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple


# ----------------------------------------------------------------------------
# Parsing
# ----------------------------------------------------------------------------
def parse_kv_stream(text: str) -> Dict[str, str]:
    kv: Dict[str, str] = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("["):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        kv[key.strip()] = value.strip()
    return kv


# ----------------------------------------------------------------------------
# Verdicts
# ----------------------------------------------------------------------------
VERDICT_OK = "✅"
VERDICT_WARN = "⚠"
VERDICT_BAD = "❌"


@dataclass
class Verdict:
    category: str
    symbol: str
    headline: str
    detail: str = ""
    skillpack_ref: str = ""


@dataclass
class Report:
    status: str
    foundry_grade: bool
    account_name: str = ""
    project_name: str = ""
    verdicts: List[Verdict] = field(default_factory=list)
    raw: Dict[str, str] = field(default_factory=dict)

    def add(self, v: Verdict) -> None:
        self.verdicts.append(v)

    def top_issues(self, n: int = 3) -> List[Verdict]:
        bad = [v for v in self.verdicts if v.symbol == VERDICT_BAD]
        warn = [v for v in self.verdicts if v.symbol == VERDICT_WARN]
        return (bad + warn)[:n]


# ----------------------------------------------------------------------------
# Verdict builders — one per topology category
# ----------------------------------------------------------------------------
def verdict_account(kv: Dict[str, str]) -> Verdict:
    name = kv.get("ACCOUNT_NAME", "")
    kind = kv.get("ACCOUNT_KIND", "")
    apm = kv.get("ACCOUNT_ALLOW_PROJECT_MANAGEMENT", "false")
    sku = kv.get("ACCOUNT_SKU", "unknown")
    if not name:
        return Verdict("Account", VERDICT_BAD, "No account found", "Resource group has no CognitiveServices/AIServices account.", "foundry-deploy/SKILL.md")
    if apm != "true":
        return Verdict(
            "Account",
            VERDICT_BAD,
            f"{name} is NOT Foundry-grade",
            f"kind={kind} sku={sku} allowProjectManagement={apm}. Hosted agents require allowProjectManagement=true. Recreate the account or pick another.",
            "foundry-deploy/SKILL.md",
        )
    return Verdict("Account", VERDICT_OK, f"{name} (kind={kind}, sku={sku})", "Foundry-grade account confirmed.", "")


def verdict_project(kv: Dict[str, str]) -> Verdict:
    count = int(kv.get("PROJECT_COUNT", "0") or 0)
    selected = kv.get("PROJECT_NAME", "")
    endpoint = kv.get("PROJECT_ENDPOINT", "")
    if count == 0:
        return Verdict("Project", VERDICT_BAD, "No projects under the account", "Add at least one project — agents live inside projects.", "foundry-deploy/SKILL.md")
    if not endpoint:
        return Verdict("Project", VERDICT_WARN, f"{selected} (no endpoint surfaced)", "The endpoints.\"AI Foundry API\" property was missing. Some assessments (hosted-agent listing) may be skipped.", "foundry-deploy/rest-api.md")
    extra = "" if count == 1 else f" (1 of {count})"
    return Verdict("Project", VERDICT_OK, f"{selected}{extra}", f"Endpoint: {endpoint}", "")


def verdict_connections(kv: Dict[str, str]) -> List[Verdict]:
    out: List[Verdict] = []
    count = int(kv.get("CONNECTION_COUNT", "0") or 0)
    cats = kv.get("CONNECTION_CATEGORIES", "")
    if count == 0:
        out.append(Verdict(
            "Connections",
            VERDICT_WARN,
            "Project has zero connections",
            "Knowledge sources (AI Search, Storage, Fabric, AOAI) need explicit connections before they can be wired into agents.",
            "foundry-knowledge/SKILL.md",
        ))
        return out

    out.append(Verdict("Connections", VERDICT_OK, f"{count} connection(s) on project", f"Categories: {cats or 'unknown'}", ""))

    # Per-category nudges
    if "AzureAISearch" in cats:
        out.append(Verdict("Knowledge / AI Search", VERDICT_OK, "AzureAISearch connection present", "Wire this in agent-capabilities.yaml knowledge.sources[] as type: ai_search.", "foundry-knowledge/SKILL.md"))
    if "CosmosDB" in cats:
        out.append(Verdict("Memory / Cosmos", VERDICT_OK, "CosmosDB connection present", "Capability host (memory/thread store) can bind this. Cross-check CAPHOST verdict.", "foundry-deploy/capabilities-manifest.md"))
    if "FabricEngagement" in cats:
        out.append(Verdict("Fabric", VERDICT_OK, "FabricEngagement connection present", "fabric.enabled=true in agent-capabilities.yaml can use this workspace.", "foundry-fabric/SKILL.md"))
    if "AzureBlob" in cats or "AzureStorageAccount" in cats:
        out.append(Verdict("Storage", VERDICT_OK, "Storage connection present", "File-search / blob-via-search knowledge paths can bind this.", "foundry-knowledge/SKILL.md"))
    return out


def verdict_capability_hosts(kv: Dict[str, str]) -> Verdict:
    """Distinguish account-scope vs project-scope capability hosts.

    Per Foundry capability-hosts doc, the project-level one is what Agent
    Service actually reads for BYO bindings (threadStorage / vectorStore /
    storage). The account-level one is a prerequisite that must exist before
    the project one can be created. Four cases:

    * neither               → ⚠ no capability host at any scope → agents use
                              Microsoft-managed default state. Run
                              `/add-capability-host` to wire BYO.
    * account only          → ⚠ account capHost exists but project one
                              missing → BYO connections aren't active yet.
                              Run `/add-capability-host --scope project`.
    * project only          → ⚠ shouldn't normally happen (the API requires
                              account first) but possible during partial
                              teardown. Surface as anomalous.
    * both, project has BYO → ✅ standard agent setup is fully wired.
    * both, project bare    → ⚠ project capHost present but no
                              thread/vector/storage connections bound.
    """
    proj_count = int(kv.get("CAPHOST_PROJECT_COUNT", kv.get("CAPHOST_COUNT", "0")) or 0)
    acct_count = int(kv.get("CAPHOST_ACCOUNT_COUNT", "0") or 0)

    ref = "foundry-deploy/capability-host-bootstrap.md"
    remediation = "Run `/add-capability-host` to wire BYO Cosmos + AI Search + Storage."

    if acct_count == 0 and proj_count == 0:
        return Verdict(
            "Capability hosts",
            VERDICT_WARN,
            "No capability hosts (account or project scope)",
            f"Agent Service falls back to Microsoft-managed default state. {remediation} "
            f"Note: the account-level capability host is a prerequisite for the project-level one (409 otherwise) — the script will create both in order.",
            ref,
        )

    if acct_count > 0 and proj_count == 0:
        acct_name = kv.get("CAPHOST_ACCOUNT_1_NAME", "(unnamed)")
        acct_kind = kv.get("CAPHOST_ACCOUNT_1_KIND", "unknown")
        return Verdict(
            "Capability hosts",
            VERDICT_WARN,
            f"Account capHost '{acct_name}' (kind={acct_kind}) exists, project capHost missing",
            f"Agent Service is enabled at the account scope but no project-level BYO bindings are active — agents will still use default platform-managed state. "
            f"Run `/add-capability-host --scope project` to bind Cosmos/AI Search/Storage to project '{kv.get('PROJECT_NAME','')}'.",
            ref,
        )

    if proj_count > 0 and acct_count == 0:
        return Verdict(
            "Capability hosts",
            VERDICT_WARN,
            f"Anomalous: project capHost present but no account-level capHost",
            "This shouldn't normally happen (API requires account first). Likely a partial teardown. "
            "Re-create the account-level host via `/add-capability-host --scope account`, then verify the project one still points at valid connections.",
            ref,
        )

    # Both exist. Inspect project bindings.
    proj_name = kv.get("CAPHOST_PROJECT_1_NAME", kv.get("CAPHOST_1_NAME", "(unnamed)"))
    proj_kind = kv.get("CAPHOST_PROJECT_1_KIND", kv.get("CAPHOST_1_KIND", "unknown"))
    thread_csv = kv.get("CAPHOST_PROJECT_1_THREAD_CONNECTIONS", "")
    vector_csv = kv.get("CAPHOST_PROJECT_1_VECTOR_CONNECTIONS", "")
    storage_csv = kv.get("CAPHOST_PROJECT_1_STORAGE_CONNECTIONS", "")
    aiservices_csv = kv.get("CAPHOST_PROJECT_1_AISERVICES_CONNECTIONS", "")

    bindings = [b for b in (thread_csv, vector_csv, storage_csv) if b]
    if len(bindings) == 3:
        ai_note = f" + aiServices={aiservices_csv}" if aiservices_csv else ""
        return Verdict(
            "Capability hosts",
            VERDICT_OK,
            f"Project capHost '{proj_name}' fully wired (thread + vector + storage)",
            f"Bindings: thread={thread_csv} vector={vector_csv} storage={storage_csv}{ai_note}. "
            f"Account capHost ({kv.get('CAPHOST_ACCOUNT_1_NAME','')}) present as required prerequisite.",
            ref,
        )

    missing = []
    if not thread_csv: missing.append("threadStorage (Cosmos)")
    if not vector_csv: missing.append("vectorStore (AI Search)")
    if not storage_csv: missing.append("storage (Storage Account)")
    return Verdict(
        "Capability hosts",
        VERDICT_WARN,
        f"Project capHost '{proj_name}' present but BYO bindings partial",
        f"Missing: {', '.join(missing)}. capabilityHosts can't be updated — "
        f"`/add-capability-host --force-recreate` will delete and recreate with full bindings (after explicit consent).",
        ref,
    )


def verdict_network(kv: Dict[str, str]) -> Verdict:
    cls = kv.get("NETWORK_CLASS", "unknown")
    pub = kv.get("ACCOUNT_PUBLIC_NETWORK_ACCESS", "unknown")
    pe = int(kv.get("ACCOUNT_PRIVATE_ENDPOINT_COUNT", "0") or 0)
    if cls == "public":
        return Verdict("Network", VERDICT_OK, "Public network class", "No injection. publicNetworkAccess=Enabled. Fastest path; revisit before prod if regulated.", "foundry-prod-readiness/networking.md")
    if cls == "managed-vnet":
        return Verdict("Network", VERDICT_OK, "Managed VNet injection", "Microsoft-managed subnet. Outbound to data sources still requires per-source private endpoints or firewall rules.", "foundry-prod-readiness/networking.md")
    if cls == "byo-vnet":
        return Verdict("Network", VERDICT_OK, "BYO VNet injection", "Validate that the agent subnet can reach every declared knowledge source (run /prepare-deploy with deep_network=true).", "foundry-prod-readiness/networking.md")
    if cls == "private-no-injection":
        return Verdict("Network", VERDICT_WARN, "publicNetworkAccess=Disabled but no injection found", f"PE count={pe}. Agents will not reach OUT to data sources without an injection or PE chain.", "foundry-prod-readiness/networking.md")
    return Verdict("Network", VERDICT_WARN, f"Unclear network class ({cls})", f"publicNetworkAccess={pub}, PE count={pe}. Re-run with --verbose or inspect raw JSON.", "foundry-prod-readiness/networking.md")


def verdict_deployments(kv: Dict[str, str]) -> Verdict:
    total = int(kv.get("DEPLOYMENT_TOTAL_COUNT", "0") or 0)
    own = int(kv.get("DEPLOYMENT_OWN_ACCOUNT_COUNT", "0") or 0)
    own_name = kv.get("DEPLOYMENT_OWN_ACCOUNT_NAME", "<this-account>")
    cross = total - own
    if total == 0:
        return Verdict(
            "Model deployments",
            VERDICT_BAD,
            "No model deployments in the resource group",
            "Hosted agents need at least one chat-completions deployment. Run /plan-agent Step 0b model-selection or deploy via portal.",
            "foundry-deploy/model-selection.md",
        )
    if own == 0 and cross > 0:
        return Verdict(
            "Model deployments",
            VERDICT_WARN,
            f"Zero deployments on chosen project's account ({own_name}); {cross} on sibling account(s)",
            f"Agents on this project must reference cross-account deployments by full endpoint URL (extra latency + cross-account RBAC). Consider deploying a model on '{own_name}' or re-running /assess-project against the sibling account.",
            "foundry-deploy/model-selection.md",
        )
    suffix = f" (+{cross} cross-account in this RG)" if cross > 0 else ""
    return Verdict(
        "Model deployments",
        VERDICT_OK,
        f"{own} deployment(s) on {own_name}{suffix}",
        "Per-account names available as DEPLOYMENT_ACCOUNT_<name>_NAMES.",
        "",
    )


def verdict_agents(kv: Dict[str, str]) -> Verdict:
    count = int(kv.get("AGENT_COUNT", "0") or 0)
    if count == 0:
        return Verdict("Hosted agents", VERDICT_OK, "Zero hosted agents on the project", "Greenfield. Ready for first /plan-agent + /prepare-deploy run.", "")
    names = kv.get("AGENT_NAMES", "")
    return Verdict("Hosted agents", VERDICT_OK, f"{count} agent(s) already on project", f"Names: {names}.", "")


def verdict_identity(kv: Dict[str, str]) -> Verdict:
    typ = kv.get("IDENTITY_TYPE", "None")
    sa = kv.get("IDENTITY_SYSTEM_ASSIGNED_PRINCIPAL_ID", "")
    if typ == "None" or not sa:
        return Verdict(
            "Identity",
            VERDICT_WARN,
            "Account has no system-assigned managed identity surfaced",
            "Several RBAC + Purview paths assume the account / project MI is discoverable. /configure-rbac will retry, but expect more runbook fallbacks.",
            "foundry-identity/SKILL.md",
        )
    return Verdict("Identity", VERDICT_OK, f"Account identity type={typ}", f"Principal id captured ({sa[:8]}…). /configure-rbac can fan out grants.", "")


# ----------------------------------------------------------------------------
# Builders
# ----------------------------------------------------------------------------
def build_report(kv: Dict[str, str]) -> Report:
    status = kv.get("TOPOLOGY_STATUS", "unknown")
    foundry_grade = kv.get("TOPOLOGY_FOUNDRY_GRADE", "false") == "true"
    rep = Report(
        status=status,
        foundry_grade=foundry_grade,
        account_name=kv.get("ACCOUNT_NAME", ""),
        project_name=kv.get("PROJECT_NAME", ""),
        raw=kv,
    )

    rep.add(verdict_account(kv))
    if not foundry_grade:
        # Stop early — downstream verdicts make no sense.
        return rep

    rep.add(verdict_project(kv))
    if status == "no-project":
        return rep

    for v in verdict_connections(kv):
        rep.add(v)
    rep.add(verdict_capability_hosts(kv))
    rep.add(verdict_network(kv))
    rep.add(verdict_deployments(kv))
    rep.add(verdict_agents(kv))
    rep.add(verdict_identity(kv))
    return rep


def render_markdown(rep: Report) -> str:
    lines: List[str] = []
    lines.append(f"# Foundry project topology — {rep.account_name or '(no account)'} / {rep.project_name or '(no project)'}")
    lines.append("")
    lines.append(f"- **Status:** `{rep.status}`")
    lines.append(f"- **Foundry-grade:** {'yes' if rep.foundry_grade else 'NO'}")
    lines.append("")
    lines.append("Verdict rubric: ✅ ready / ⚠ caveat / ❌ blocker. Re-run `/assess-project` after any fix.")
    lines.append("")
    lines.append("| | Category | Headline | Reference |")
    lines.append("|---|---|---|---|")
    for v in rep.verdicts:
        ref = f"[{v.skillpack_ref}](../{v.skillpack_ref})" if v.skillpack_ref else "—"
        head = v.headline.replace("|", "\\|")
        lines.append(f"| {v.symbol} | {v.category} | {head} | {ref} |")
    lines.append("")

    bad_or_warn = rep.top_issues(3)
    if bad_or_warn:
        lines.append("## Top 3 things to look at")
        lines.append("")
        for i, v in enumerate(bad_or_warn, start=1):
            lines.append(f"{i}. **{v.category} — {v.symbol} {v.headline}.** {v.detail}")
            if v.skillpack_ref:
                lines.append(f"   Reference: `{v.skillpack_ref}`")
        lines.append("")
    else:
        lines.append("## Top 3 things to look at")
        lines.append("")
        lines.append("Nothing to flag. Topology is clean.")
        lines.append("")

    lines.append("## Detail by category")
    lines.append("")
    for v in rep.verdicts:
        lines.append(f"### {v.symbol} {v.category}")
        lines.append("")
        lines.append(f"- **Headline:** {v.headline}")
        if v.detail:
            lines.append(f"- **Detail:** {v.detail}")
        if v.skillpack_ref:
            lines.append(f"- **Reference:** `{v.skillpack_ref}`")
        lines.append("")

    return "\n".join(lines)


def render_json(rep: Report) -> str:
    return json.dumps({
        "status": rep.status,
        "foundry_grade": rep.foundry_grade,
        "account": rep.account_name,
        "project": rep.project_name,
        "verdicts": [
            {
                "category": v.category,
                "symbol": v.symbol,
                "headline": v.headline,
                "detail": v.detail,
                "reference": v.skillpack_ref,
            }
            for v in rep.verdicts
        ],
        "raw": rep.raw,
    }, indent=2)


def render_stub_manifest(rep: Report) -> str:
    """Emit an agent-capabilities.draft.yaml pre-filled from topology.
    Every uncertain value is left as a TODO comment so the user must opt in.
    """
    kv = rep.raw
    lines: List[str] = []
    lines.append("# agent-capabilities.draft.yaml — generated by /assess-project")
    lines.append("# Review every TODO before promoting to agent-capabilities.yaml.")
    lines.append("# Schema reference: foundry-deploy/capabilities-manifest.md")
    lines.append("")
    lines.append("agent_kind: hosted  # TODO: change to 'prompt' for prompt-only agents")
    lines.append("operator_mode: true  # TODO: set false for SOC-monitored envs")
    lines.append("")
    lines.append("target:")
    lines.append(f"  subscription_id: {kv.get('SUBSCRIPTION_ID', '<sub>')}")
    lines.append(f"  resource_group: {kv.get('RESOURCE_GROUP', '<rg>')}")
    lines.append(f"  foundry_account: {kv.get('ACCOUNT_NAME', '<account>')}")
    lines.append(f"  project: {kv.get('PROJECT_NAME', '<project>')}")
    lines.append(f"  location: {kv.get('PROJECT_LOCATION', kv.get('ACCOUNT_LOCATION', '<location>'))}")
    lines.append("")
    lines.append("# deploy_mode: container (default) | code (preview)")
    lines.append("deploy_mode: container  # TODO: set 'code' if shipping a source zip")
    lines.append("")

    # Network
    cls = kv.get("NETWORK_CLASS", "public")
    lines.append("network:")
    lines.append(f"  class: {cls}  # discovered from networkInjections + publicNetworkAccess")
    if cls == "byo-vnet":
        lines.append(f"  byo_vnet:")
        lines.append(f"    subnet_id: {kv.get('NETWORK_INJECTION_SUBNET', '<subnet-arm-id>')}")
        lines.append("    # TODO: add firewall_id if /prepare-deploy deep_network=true")
    lines.append("")

    # Knowledge — auto-suggest from connections
    cats = kv.get("CONNECTION_CATEGORIES", "")
    if cats:
        lines.append("knowledge:")
        lines.append("  sources: []  # TODO: enable individual sources below")
        for k in range(1, int(kv.get("CONNECTION_COUNT", "0") or 0) + 1):
            cn = kv.get(f"CONNECTION_{k}_NAME", "")
            cc = kv.get(f"CONNECTION_{k}_CATEGORY", "")
            if not cn:
                continue
            kind = {
                "AzureAISearch": "ai_search",
                "AzureBlob": "blob",
                "AzureStorageAccount": "blob",
                "FabricEngagement": "fabric",
                "CosmosDB": "cosmos",
            }.get(cc, cc.lower())
            lines.append(f"  # - name: {cn}")
            lines.append(f"  #   type: {kind}")
            lines.append(f"  #   connection: {cn}")
        lines.append("")
    else:
        lines.append("# knowledge: (no connections discovered — add via portal first)")
        lines.append("")

    # Fabric
    if "FabricEngagement" in cats:
        lines.append("fabric:")
        lines.append("  enabled: false  # TODO: set true and wire workspace if Fabric Data Agent")
        lines.append("")

    # Purview
    lines.append("purview:")
    lines.append("  enabled: false  # TODO: enable if tenant licensed (E5)")
    lines.append("")

    lines.append("# Capability hosts on project (informational):")
    caph_count = int(kv.get("CAPHOST_COUNT", "0") or 0)
    if caph_count > 0:
        for k in range(1, caph_count + 1):
            lines.append(
                f"#   - {kv.get(f'CAPHOST_{k}_NAME', '')} (kind={kv.get(f'CAPHOST_{k}_KIND', '')}, "
                f"memory={kv.get(f'CAPHOST_{k}_MEMORY_COUNT', '0')}, "
                f"thread={kv.get(f'CAPHOST_{k}_THREAD_COUNT', '0')}, "
                f"vector={kv.get(f'CAPHOST_{k}_VECTOR_COUNT', '0')})"
            )
    else:
        lines.append("#   (none — ephemeral state until at least one capabilityHost is bound)")
    lines.append("")
    return "\n".join(lines)


# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="Format Foundry project topology")
    ap.add_argument("--input", type=Path, default=None, help="KEY=VALUE input file (default: stdin)")
    ap.add_argument("--out-dir", type=Path, default=Path("."), help="Directory to write artifacts into")
    ap.add_argument("--no-stub", action="store_true", help="Skip agent-capabilities.draft.yaml")
    ap.add_argument("--quiet", action="store_true", help="Only write files; suppress stdout summary")
    args = ap.parse_args(argv)

    text = args.input.read_text() if args.input else sys.stdin.read()
    kv = parse_kv_stream(text)
    rep = build_report(kv)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    md_path = args.out_dir / "project-topology.md"
    json_path = args.out_dir / "project-topology.json"
    md_path.write_text(render_markdown(rep))
    json_path.write_text(render_json(rep))

    stub_path: Optional[Path] = None
    if not args.no_stub and rep.foundry_grade:
        stub_path = args.out_dir / "agent-capabilities.draft.yaml"
        stub_path.write_text(render_stub_manifest(rep))

    if not args.quiet:
        print(f"Wrote: {md_path}")
        print(f"Wrote: {json_path}")
        if stub_path:
            print(f"Wrote: {stub_path}")
        print()
        for v in rep.top_issues(3):
            print(f"{v.symbol} {v.category}: {v.headline}")

    # Exit code mirrors the shell script intent:
    # 0 — ok / 2 — not-foundry-grade / 3 — no-account
    if rep.status == "no-account":
        return 3
    if rep.status == "not-foundry-grade":
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
