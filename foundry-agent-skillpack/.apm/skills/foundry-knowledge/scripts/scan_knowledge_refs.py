#!/usr/bin/env python3
"""Brownfield knowledge-source scan.

Scans Python source files for signals that the agent already references a
knowledge source, then prints a draft `knowledge.sources[]` block the user can
review and paste into agent-capabilities.yaml.

REGEX-ONLY by design (no AST, no framework introspection). Heuristics are
conservative: when uncertain we surface the file/line + ask the user.

Targeted frameworks (per current scope):
  - agent-framework / agent-framework-foundry-hosting
  - LangGraph + langchain-azure-ai

Usage:
  python scan_knowledge_refs.py --agent-path agents/<name> [--format json|yaml]

Exit codes:
  0  scan complete (with or without findings)
  2  agent-path doesn't exist or has no .py files

The scan NEVER auto-modifies agent-capabilities.yaml. It prints a draft for the
user to confirm + edit. This matches the agreed skillpack rule: code scan is a
signal, not a source of truth.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


# ── Signal table ────────────────────────────────────────────────────────────
# Each entry: (regex, kind_hint, why)
# kind_hint may be None when the signal is ambiguous; we still surface it.
SIGNALS: list[tuple[re.Pattern[str], str | None, str]] = [
    # AI Search
    (re.compile(r"\bfrom\s+azure\.search\.documents"),                 "ai_search_direct", "imports azure.search.documents"),
    (re.compile(r"\bSearchClient\s*\("),                                "ai_search_direct", "instantiates SearchClient"),
    (re.compile(r"\b(?:azure_)?ai_search\b",re.I),                     "ai_search_direct", "references ai_search tool"),
    (re.compile(r"langchain_community\.vectorstores\.AzureSearch"),    "ai_search_direct", "LangChain AzureSearch vector store"),

    # Foundry IQ (KB MCP)
    (re.compile(r"knowledge_base_retrieve"),                            "foundry_iq",       "uses knowledge_base_retrieve MCP tool"),
    (re.compile(r"\bRemoteTool\b.*\bProjectManagedIdentity\b", re.I),   "foundry_iq",       "RemoteTool + ProjectManagedIdentity (Foundry IQ pattern)"),
    (re.compile(r'kind\s*=\s*["\']foundry_iq["\']', re.I),              "foundry_iq",       "explicit foundry_iq kind"),

    # File search
    (re.compile(r"\bfile_search\b", re.I),                              "file_search_basic","references file_search tool"),
    (re.compile(r"\bcreate_vector_store\b", re.I),                      "file_search_basic","creates a vector store (file_search pattern)"),

    # Blob (ambiguous — could be source data or checkpoint)
    (re.compile(r"\bBlobServiceClient\s*\("),                            None,              "BlobServiceClient — could be source data, checkpoint, or sink. Confirm intent."),
    (re.compile(r"\bContainerClient\s*\("),                              None,              "ContainerClient — same ambiguity as BlobServiceClient."),
    (re.compile(r"\bBlobClient\s*\("),                                   None,              "BlobClient — same ambiguity."),

    # Fabric (multi-surface)
    (re.compile(r"https?://[\w.-]*fabric\.microsoft\.com"),              "fabric_data_agent","references fabric.microsoft.com URL — ambiguous (Workspace API, Lakehouse SQL, Data Agent, OneLake)"),
    (re.compile(r"\bDeltaTable\s*\("),                                   "fabric_direct_delta", "DeltaTable() — direct Delta read pattern"),
    (re.compile(r"\bdeltalake\b"),                                       "fabric_direct_delta", "imports deltalake"),

    # Cosmos (rarely a knowledge source — usually app state — flag for explicit confirm)
    (re.compile(r"\bazure\.cosmos\b"),                                   None,              "azure.cosmos — usually session state, NOT a knowledge source. Confirm."),

    # Identity / connection patterns
    (re.compile(r"DefaultAzureCredential\s*\("),                         None,              "DefaultAzureCredential — neutral; identity setup."),
    (re.compile(r'auth\s*=\s*["\']api_key["\']', re.I),                  None,              "API-key auth — flagged: incompatible with private VNet on AI Search."),
]


# ── Data ────────────────────────────────────────────────────────────────────
@dataclass
class Hit:
    file: str
    line_no: int
    line: str
    kind_hint: str | None
    why: str


@dataclass
class ScanResult:
    hits: list[Hit] = field(default_factory=list)
    files_scanned: int = 0


# ── Scan ────────────────────────────────────────────────────────────────────
def scan(agent_path: Path) -> ScanResult:
    result = ScanResult()
    py_files = sorted(agent_path.rglob("*.py"))
    for py in py_files:
        # Skip caches / venvs
        if any(seg in py.parts for seg in ("__pycache__", ".venv", "venv", "site-packages")):
            continue
        try:
            text = py.read_text(encoding="utf-8")
        except Exception:
            continue
        result.files_scanned += 1
        for line_no, line in enumerate(text.splitlines(), start=1):
            for pattern, kind, why in SIGNALS:
                if pattern.search(line):
                    result.hits.append(Hit(
                        file=str(py.relative_to(agent_path)),
                        line_no=line_no,
                        line=line.strip(),
                        kind_hint=kind,
                        why=why,
                    ))
    return result


# ── Render draft ────────────────────────────────────────────────────────────
def render_draft_yaml(hits: list[Hit]) -> str:
    """Group hits by kind_hint; emit a knowledge.sources[] block draft."""
    by_kind: dict[str, list[Hit]] = {}
    ambiguous: list[Hit] = []
    for h in hits:
        if h.kind_hint:
            by_kind.setdefault(h.kind_hint, []).append(h)
        else:
            ambiguous.append(h)

    lines = ["# Draft knowledge.sources[] — REVIEW + EDIT before pasting into agent-capabilities.yaml"]
    lines.append("knowledge:")
    lines.append("  sources:")

    for kind, kind_hits in sorted(by_kind.items()):
        sample_lines = "\n".join(f"    #   {h.file}:{h.line_no}  ({h.why})" for h in kind_hits[:3])
        lines.append(f"    # ── {kind} (signal from {len(kind_hits)} line(s)) ─────────────────────────")
        lines.append(sample_lines)
        lines.append(f"    - name: TODO-{kind.replace('_','-')}")
        lines.append(f"      kind: {kind}")
        # Per-kind required fields the user must fill in.
        if kind == "foundry_iq":
            lines += [
                "      knowledge_base_name: TODO",
                "      search_resource_id:  TODO",
                "      project_connection_name: TODO",
                "      acl_passthrough: false",
            ]
        elif kind == "ai_search_direct":
            lines += [
                "      resource_id: TODO",
                "      index_name:  TODO",
                "      auth: managed_identity",
            ]
        elif kind == "file_search_basic":
            pass
        elif kind == "file_search_standard":
            lines += [
                "      search_resource_id:  TODO",
                "      storage_resource_id: TODO",
            ]
        elif kind == "blob_via_indexer":
            lines += [
                "      storage_resource_id: TODO",
                "      container:           TODO",
                "      search_resource_id:  TODO",
                "      index_name:          TODO",
                "      indexer_name:        TODO",
                "      data_source_name:    TODO",
                "      schedule:            PT1H",
                "      ingest_acls:         false",
                "      change_tracking:     true",
            ]
        elif kind == "fabric_data_agent":
            lines += [
                "      # See foundry-fabric/SKILL.md (Path A — NL2SQL via Toolbox)",
                "      # WARNING: HARD BLOCK if network.class != public",
                "      connection_name: TODO",
            ]
        elif kind == "fabric_direct_delta":
            lines += [
                "      # See foundry-fabric/SKILL.md (Path B — Direct Delta read)",
                "      # WARNING: HARD BLOCK if network.class != public",
                "      lakehouse_sql_endpoint: TODO",
                "      table:                  TODO",
            ]

    if ambiguous:
        lines.append("")
        lines.append("# ── Ambiguous signals (NOT auto-classified) — confirm with user ─────────────")
        for h in ambiguous:
            lines.append(f"#   {h.file}:{h.line_no}  {h.why}")
            lines.append(f"#     {h.line}")

    return "\n".join(lines) + "\n"


def render_json(result: ScanResult) -> str:
    return json.dumps({
        "files_scanned": result.files_scanned,
        "hits": [vars(h) for h in result.hits],
    }, indent=2)


# ── CLI ─────────────────────────────────────────────────────────────────────
def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--agent-path", required=True)
    p.add_argument("--format", choices=["yaml", "json"], default="yaml",
                   help="yaml: draft knowledge block; json: structured findings")
    args = p.parse_args()

    ap = Path(args.agent_path)
    if not ap.exists():
        print(f"[x] agent-path not found: {ap}", file=sys.stderr)
        return 2
    if not any(ap.rglob("*.py")):
        print(f"[!] No .py files under {ap}", file=sys.stderr)
        return 2

    result = scan(ap)

    print(f"# Scanned {result.files_scanned} file(s); found {len(result.hits)} signal line(s).", file=sys.stderr)
    if not result.hits:
        print(f"# No knowledge-source signals detected. If this agent SHOULD have knowledge sources,", file=sys.stderr)
        print(f"# author them from scratch using the schema in agent-capabilities.yaml.", file=sys.stderr)
        return 0

    if args.format == "yaml":
        print(render_draft_yaml(result.hits))
    else:
        print(render_json(result))

    print("\n# IMPORTANT: this is a DRAFT. Do not paste without reviewing every TODO + each", file=sys.stderr)
    print("# ambiguous signal. Code scan is a signal, not a source of truth.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
