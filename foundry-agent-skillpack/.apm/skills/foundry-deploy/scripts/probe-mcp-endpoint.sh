#!/usr/bin/env bash
# Probe an MCP endpoint for reachability (FB-13). Replaces the leaked
# `curl -s -o /dev/null -w "%{http_code}"` plumbing in /prepare-deploy.
#
# Treats 200, 401, 403, 405, 426 as REACHABLE — the endpoint is alive, the
# auth is the agent's problem to solve later. Only network errors (timeout,
# DNS, connection refused) are UNREACHABLE.
#
# Usage:
#   ./probe-mcp-endpoint.sh <url> [<server_label>]
#
# Output:
#   MCP_URL=<url>
#   MCP_LABEL=<label>
#   MCP_HTTP_STATUS=<code or "network-error">
#   MCP_REACHABLE=true|false
#   MCP_LATENCY_MS=<ms>
#
# Exit codes:
#   0 — reachable
#   2 — unreachable (network error / 5xx / 404)
set -euo pipefail

URL="${1:?usage: $0 <url> [<label>]}"
LABEL="${2:-mcp}"
TIMEOUT="${MCP_PROBE_TIMEOUT_S:-8}"

echo "MCP_URL=$URL"
echo "MCP_LABEL=$LABEL"

# -w gives status_code + time_total; trap connect errors via exit code.
RESPONSE="$(curl -sS -o /dev/null \
  --max-time "$TIMEOUT" \
  -w '%{http_code} %{time_total}' \
  "$URL" 2>/tmp/.probe-mcp.err || echo 'network-error 0')"

STATUS="$(echo "$RESPONSE" | awk '{print $1}')"
LATENCY_S="$(echo "$RESPONSE" | awk '{print $2}')"
LATENCY_MS="$(awk -v s="$LATENCY_S" 'BEGIN{printf "%d", s*1000}')"

echo "MCP_HTTP_STATUS=$STATUS"
echo "MCP_LATENCY_MS=$LATENCY_MS"

case "$STATUS" in
  200|401|403|405|426)
    echo "MCP_REACHABLE=true"
    rm -f /tmp/.probe-mcp.err
    exit 0
    ;;
  network-error)
    ERR="$(cat /tmp/.probe-mcp.err 2>/dev/null | head -1)"
    echo "MCP_REACHABLE=false"
    echo "MCP_ERROR=$ERR"
    rm -f /tmp/.probe-mcp.err
    exit 2
    ;;
  *)
    echo "MCP_REACHABLE=false"
    rm -f /tmp/.probe-mcp.err
    exit 2
    ;;
esac
