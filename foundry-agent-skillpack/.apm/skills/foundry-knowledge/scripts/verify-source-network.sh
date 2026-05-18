#!/usr/bin/env bash
# Verify network-class compatibility for a single knowledge source.
#
# Wraps the four detection scripts under foundry-prod-readiness/scripts/network/
# and applies the source-kind compatibility matrix.
#
# Usage:
#   ./verify-source-network.sh <kind> <resource_id> <foundry_network_class> [<agent_vnet_id>]
#
# <kind> — see verify-source-rbac.sh for supported list
# <foundry_network_class> — public | managed_vnet | byo_vnet
# <agent_vnet_id> — required when foundry_network_class != public (for DNS link check)
#
# Exit codes:
#   0  compatible (with or without warnings on stderr)
#   1  HARD BLOCK (e.g., fabric_* on a non-public foundry network class)
#   2  detection failed (Reader missing, resource not found, etc.)
set -euo pipefail

KIND="${1:?usage: $0 <kind> <resource_id> <foundry_network_class> [<agent_vnet_id>]}"
RID="${2:?}"
NETCLASS="${3:?}"
VNET_ID="${4:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_DIR="$SCRIPT_DIR/../../foundry-prod-readiness/scripts/network"

# Hard-block matrix. Update when Fabric private link lands.
case "$KIND:$NETCLASS" in
  fabric_data_agent:managed_vnet|fabric_data_agent:byo_vnet| \
  fabric_direct_delta:managed_vnet|fabric_direct_delta:byo_vnet)
    echo "[x] HARD BLOCK: $KIND is not supported when network.class=$NETCLASS." >&2
    echo "    Fabric workspace-level private link is unsupported for hosted agents today." >&2
    echo "    Mitigations: (1) move data to AI Search via blob_via_indexer, OR" >&2
    echo "                 (2) run a separate public-class Foundry account for this agent (A2A from VNet-isolated peer)," >&2
    echo "                 (3) wait for Fabric workspace PL → hosted agent support." >&2
    exit 1
    ;;
esac

# Skip resource-level checks for kinds that don't have an Azure resource id (file_search_basic).
if [[ "$KIND" == "file_search_basic" ]]; then
  echo "[+] file_search_basic is Microsoft-managed; no per-source network check." >&2
  if [[ "$NETCLASS" != "public" ]]; then
    echo "[!] On non-public Foundry, verify FQDN allowlist permits MSFT-managed search/storage egress." >&2
  fi
  exit 0
fi

# 1. Source posture.
if ! "$NET_DIR/check-source-network.sh" "$RID" >/tmp/vsn.out 2>/tmp/vsn.err; then
  rc=$?
  if (( rc == 2 )); then
    echo "[!] Could not read $RID for network check." >&2
    cat /tmp/vsn.err >&2
    exit 2
  fi
fi
. /tmp/vsn.out 2>/dev/null || true   # imports PUBLIC_NETWORK_ACCESS, ACL_DEFAULT_ACTION, PE_COUNT, etc.

# 2. PE state when Foundry is non-public AND source is non-public.
if [[ "$NETCLASS" != "public" && "${PUBLIC_NETWORK_ACCESS:-Enabled}" == "Disabled" ]]; then
  if ! "$NET_DIR/check-private-endpoint.sh" "$RID" >/dev/null 2>&1; then
    echo "[!] Could not enumerate private endpoints on $RID" >&2
  fi
  if (( ${PE_COUNT:-0} == 0 )); then
    echo "[x] HARD BLOCK: $KIND requires connectivity but $(basename "$RID") has publicNetworkAccess=Disabled and no PE." >&2
    exit 1
  fi
fi

# 3. DNS link (only relevant for non-public Foundry + sources with PE).
if [[ -n "$VNET_ID" && "$NETCLASS" != "public" && "${PE_COUNT:-0}" -gt 0 ]]; then
  case "$KIND" in
    foundry_iq|ai_search_direct|blob_via_indexer|file_search_standard)
      "$NET_DIR/check-private-dns.sh" "$VNET_ID" ai_search >/tmp/vsn.dns 2>/dev/null || true
      . /tmp/vsn.dns 2>/dev/null || true
      if [[ "${ZONE_LINKED_TO_VNET:-false}" != "true" ]]; then
        echo "[!] DNS zone privatelink.search.windows.net is NOT linked to agent VNet — PE will resolve to public IP." >&2
      fi
      ;;
  esac
  if [[ "$KIND" == "blob_via_indexer" || "$KIND" == "file_search_standard" ]]; then
    "$NET_DIR/check-private-dns.sh" "$VNET_ID" storage_blob >/tmp/vsn.dns 2>/dev/null || true
    . /tmp/vsn.dns 2>/dev/null || true
    if [[ "${ZONE_LINKED_TO_VNET:-false}" != "true" ]]; then
      echo "[!] DNS zone privatelink.blob.core.windows.net is NOT linked to agent VNet — PE will resolve to public IP." >&2
    fi
  fi
fi

# 4. Key-auth on AI Search + private VNet warning.
if [[ "$KIND" == "ai_search_direct" && "$NETCLASS" != "public" && "${PUBLIC_NETWORK_ACCESS:-Enabled}" == "Disabled" ]]; then
  echo "[!] Reminder: API-key auth on AI Search is broken with private VNet. Use managed identity." >&2
fi

echo "[+] $KIND on $(basename "$RID") is compatible with foundry_network_class=$NETCLASS"
exit 0
