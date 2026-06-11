#!/usr/bin/env bash
# Inspect a linked Azure Container Registry for hosted-agent images (FB-6).
# Returns repo count, top tags, and reachability. Used by /assess-project
# (Track H discovery completeness) and /prepare-deploy (Step 3 validation
# of services.<svc>.containers.registry).
#
# Usage:
#   ./discover-acr.sh <acr_name> [<resource_group> [<subscription_id>]]
#
# Output (stdout, KEY=VALUE):
#   ACR_NAME=...
#   ACR_LOGIN_SERVER=...
#   ACR_SKU=Basic|Standard|Premium
#   ACR_REACHABLE=true|false
#   ACR_REPOSITORY_COUNT=<n>
#   ACR_REPOSITORIES=name1,name2,...        (capped at 20)
#   ACR_TOP_REPOSITORY=<most-recent>
#   ACR_TOP_REPOSITORY_TAGS=tag1,tag2,...   (capped at 5)
#   ACR_ADMIN_ENABLED=true|false
#
# Exit codes:
#   0 — ACR found and read
#   2 — ACR not found in given RG / subscription
#   3 — ACR found but caller not authorized to list repositories
set -euo pipefail

ACR="${1:?usage: $0 <acr_name> [<rg> [<sub>]]}"
RG="${2:-}"
SUB="${3:-}"

AZ_FLAGS=()
[[ -n "$SUB" ]] && AZ_FLAGS+=(--subscription "$SUB")

# Resolve ACR (RG-scoped if RG given, else subscription-wide)
if [[ -n "$RG" ]]; then
  ACR_JSON="$(az acr show -n "$ACR" -g "$RG" "${AZ_FLAGS[@]}" -o json 2>/dev/null || echo "")"
else
  ACR_JSON="$(az acr show -n "$ACR" "${AZ_FLAGS[@]}" -o json 2>/dev/null || echo "")"
fi

if [[ -z "$ACR_JSON" ]]; then
  echo "[x] ACR '$ACR' not found${RG:+ in RG $RG}${SUB:+ (sub $SUB)}" >&2
  echo "ACR_NAME=$ACR"
  echo "ACR_REACHABLE=false"
  exit 2
fi

LOGIN_SERVER="$(echo "$ACR_JSON" | jq -r '.loginServer // ""')"
SKU="$(echo "$ACR_JSON" | jq -r '.sku.name // ""')"
ADMIN_ENABLED="$(echo "$ACR_JSON" | jq -r '.adminUserEnabled // false')"

echo "ACR_NAME=$ACR"
echo "ACR_LOGIN_SERVER=$LOGIN_SERVER"
echo "ACR_SKU=$SKU"
echo "ACR_ADMIN_ENABLED=$ADMIN_ENABLED"

# Repository listing — requires AcrPull or richer. Capture stderr so we can
# distinguish "no repos" from "403 not authorized".
REPOS_JSON="$(az acr repository list -n "$ACR" "${AZ_FLAGS[@]}" -o json 2>/tmp/.discover-acr.err || echo "")"
if [[ -z "$REPOS_JSON" ]]; then
  if grep -qi 'unauthorized\|forbidden\|denied' /tmp/.discover-acr.err 2>/dev/null; then
    echo "ACR_REACHABLE=true"
    echo "ACR_REPOSITORY_COUNT=unknown"
    echo "[!] Caller lacks AcrPull on $ACR — repository inventory unavailable" >&2
    rm -f /tmp/.discover-acr.err
    exit 3
  fi
  REPOS_JSON="[]"
fi
rm -f /tmp/.discover-acr.err

REPO_COUNT="$(echo "$REPOS_JSON" | jq 'length')"
echo "ACR_REACHABLE=true"
echo "ACR_REPOSITORY_COUNT=$REPO_COUNT"

if (( REPO_COUNT > 0 )); then
  REPO_LIST="$(echo "$REPOS_JSON" | jq -r '.[0:20] | join(",")')"
  echo "ACR_REPOSITORIES=$REPO_LIST"

  # Top repo (first one) and its most recent tags
  TOP_REPO="$(echo "$REPOS_JSON" | jq -r '.[0]')"
  echo "ACR_TOP_REPOSITORY=$TOP_REPO"
  TAGS_JSON="$(az acr repository show-tags -n "$ACR" --repository "$TOP_REPO" --orderby time_desc --top 5 "${AZ_FLAGS[@]}" -o json 2>/dev/null || echo "[]")"
  TOP_TAGS="$(echo "$TAGS_JSON" | jq -r 'if type=="array" then join(",") else . end')"
  echo "ACR_TOP_REPOSITORY_TAGS=$TOP_TAGS"
fi

exit 0
