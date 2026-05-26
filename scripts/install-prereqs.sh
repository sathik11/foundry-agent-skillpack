#!/usr/bin/env bash
# install-prereqs.sh — install hard prerequisites for foundry-agent-skillpack
#
# Supports: macOS (brew), Debian/Ubuntu (apt), WSL2 Ubuntu (apt).
# Native Windows (PowerShell / cmd): NOT supported — install WSL2 first
# (`wsl --install`) and re-run this script inside WSL. Tracked under TD-28.
#
# Skips (you must do these manually):
#   - `az login` (interactive)
#   - `az account set --subscription <id>` (you pick)
#   - RBAC role assignment (needs an Azure Owner / User Access Administrator)
#
# Flags:
#   --dry-run     Print what would be installed; install nothing.
#   --no-python   Skip Python 3.12 check (use pyenv / your own).
#   --no-azd      Skip azd + azd ai agent extension (eval-only consumers).
#
# Re-running is safe — every step checks before installing.

set -euo pipefail

# ---------------------------------------------------------------------------
# 0. Guard: must be bash on a supported OS
# ---------------------------------------------------------------------------
if [ -z "${BASH_VERSION:-}" ]; then
    echo "[!] This script must run under bash."
    echo "    Windows: install WSL2 (\`wsl --install\`) and re-run inside WSL."
    exit 1
fi

DRY_RUN=0
SKIP_PYTHON=0
SKIP_AZD=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=1 ;;
        --no-python)  SKIP_PYTHON=1 ;;
        --no-azd)     SKIP_AZD=1 ;;
        -h|--help)
            sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "[!] Unknown flag: $arg (try --help)"
            exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# 1. Detect package manager
# ---------------------------------------------------------------------------
PKG=""
SUDO=""
case "$(uname -s)" in
    Darwin)
        PKG="brew"
        command -v brew >/dev/null || {
            echo "[!] Homebrew not found. Install from https://brew.sh and re-run."
            exit 1
        }
        ;;
    Linux)
        if [ -r /etc/os-release ]; then . /etc/os-release; fi
        case "${ID:-}${ID_LIKE:-}" in
            *debian*|*ubuntu*) PKG="apt" ;;
            *) echo "[!] Unsupported Linux distro: ${ID:-unknown}. apt/brew only for now."
               echo "    Install az / azd / jq manually using your distro's package manager."
               exit 1 ;;
        esac
        [ "$(id -u)" -ne 0 ] && SUDO="sudo"
        ;;
    *)
        echo "[!] Unsupported OS: $(uname -s). macOS / Debian / Ubuntu / WSL2 only."
        exit 1 ;;
esac

if grep -qi microsoft /proc/version 2>/dev/null; then
    echo "[i] Detected WSL2 — using apt path (this is the supported Windows route)."
fi
echo "[i] OS: $(uname -s)  |  Package manager: $PKG"
echo ""

# ---------------------------------------------------------------------------
# 2. Helpers
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "    [dry-run] $*"
    else
        eval "$@"
    fi
}

ver_ge() {
    # ver_ge "1.2.3" "1.2.0" → 0 if first >= second
    [ "$1" = "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" ]
}

INSTALLED=()
SKIPPED=()
MISSING=()

# ---------------------------------------------------------------------------
# 3. apm CLI — check only (npm-based; don't pick a node manager for the user)
# ---------------------------------------------------------------------------
echo "[*] Checking apm CLI (>= 0.12) ..."
if have apm; then
    APM_VER=$(apm --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
    if ver_ge "$APM_VER" "0.12.0"; then
        echo "    ✓ apm $APM_VER"
        SKIPPED+=("apm ($APM_VER)")
    else
        echo "    ✗ apm $APM_VER is too old (need >= 0.12)."
        echo "      Upgrade: npm install -g @microsoft/apm@latest"
        MISSING+=("apm (have $APM_VER, need >= 0.12)")
    fi
else
    echo "    ✗ apm not found."
    echo "      Install: npm install -g @microsoft/apm  (requires Node.js 18+)"
    MISSING+=("apm")
fi

# ---------------------------------------------------------------------------
# 4. Azure CLI (az) — install if missing
# ---------------------------------------------------------------------------
echo ""
echo "[*] Checking Azure CLI (>= 2.80) ..."
if have az; then
    AZ_VER=$(az version --query '"azure-cli"' -o tsv 2>/dev/null || echo "0.0.0")
    if ver_ge "$AZ_VER" "2.80.0"; then
        echo "    ✓ az $AZ_VER"
        SKIPPED+=("az ($AZ_VER)")
    else
        echo "    ⚠ az $AZ_VER is older than recommended 2.80 (api-version metadata may be stale)."
        echo "      Upgrade: $PKG upgrade azure-cli  (or re-install per docs)"
        SKIPPED+=("az ($AZ_VER, upgrade recommended)")
    fi
else
    echo "    ✗ az not found. Installing ..."
    case "$PKG" in
        brew) run "brew install azure-cli" ;;
        apt)
            run "curl -sL https://aka.ms/InstallAzureCLIDeb | $SUDO bash"
            ;;
    esac
    INSTALLED+=("az")
fi

# ---------------------------------------------------------------------------
# 5. jq — install if missing
# ---------------------------------------------------------------------------
echo ""
echo "[*] Checking jq ..."
if have jq; then
    echo "    ✓ jq $(jq --version | sed 's/jq-//')"
    SKIPPED+=("jq")
else
    echo "    ✗ jq not found. Installing ..."
    case "$PKG" in
        brew) run "brew install jq" ;;
        apt)  run "$SUDO apt-get update -qq && $SUDO apt-get install -y jq" ;;
    esac
    INSTALLED+=("jq")
fi

# ---------------------------------------------------------------------------
# 6. azd + azd ai agent extension (unless --no-azd)
# ---------------------------------------------------------------------------
if [ "$SKIP_AZD" -eq 1 ]; then
    echo ""
    echo "[i] Skipping azd (--no-azd)."
else
    echo ""
    echo "[*] Checking azd (>= 1.24) ..."
    if have azd; then
        AZD_VER=$(azd version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
        if ver_ge "$AZD_VER" "1.24.0"; then
            echo "    ✓ azd $AZD_VER"
            SKIPPED+=("azd ($AZD_VER)")
        else
            echo "    ⚠ azd $AZD_VER is older than recommended 1.24."
            echo "      Upgrade: $PKG upgrade azd  (or run 'azd upgrade')"
            SKIPPED+=("azd ($AZD_VER, upgrade recommended)")
        fi
    else
        echo "    ✗ azd not found. Installing ..."
        case "$PKG" in
            brew) run "brew tap azure/azd && brew install azd" ;;
            apt)  run "curl -fsSL https://aka.ms/install-azd.sh | bash" ;;
        esac
        INSTALLED+=("azd")
    fi

    echo ""
    echo "[*] Checking azd ai agent extension ..."
    if have azd && azd extension list 2>/dev/null | grep -q "azure.ai.agents"; then
        echo "    ✓ azd ai agent extension installed"
        SKIPPED+=("azd ai agent extension")
    else
        echo "    ✗ Installing azd ai agent extension ..."
        run "azd extension install azure.ai.agents" || {
            echo "    [!] Failed (azd may need restart). Re-run after opening a new shell."
        }
        INSTALLED+=("azd ai agent extension")
    fi
fi

# ---------------------------------------------------------------------------
# 7. Python 3.12+ (unless --no-python)
# ---------------------------------------------------------------------------
if [ "$SKIP_PYTHON" -eq 1 ]; then
    echo ""
    echo "[i] Skipping Python check (--no-python)."
else
    echo ""
    echo "[*] Checking Python (>= 3.12) ..."
    PY=""
    for candidate in python3.14 python3.13 python3.12 python3 python; do
        if have "$candidate"; then PY="$candidate"; break; fi
    done
    if [ -n "$PY" ]; then
        PY_VER=$("$PY" -c 'import sys;print("%d.%d.%d"%sys.version_info[:3])' 2>/dev/null || echo "0.0.0")
        if ver_ge "$PY_VER" "3.12.0"; then
            echo "    ✓ $PY $PY_VER"
            SKIPPED+=("Python ($PY_VER via $PY)")
        else
            echo "    ✗ $PY $PY_VER too old (need >= 3.12). Installing python3.12 ..."
            case "$PKG" in
                brew) run "brew install python@3.12" ;;
                apt)  run "$SUDO apt-get update -qq && $SUDO apt-get install -y python3.12 python3-pip" ;;
            esac
            INSTALLED+=("python3.12")
        fi
    else
        echo "    ✗ No python found. Installing python3.12 ..."
        case "$PKG" in
            brew) run "brew install python@3.12" ;;
            apt)  run "$SUDO apt-get update -qq && $SUDO apt-get install -y python3.12 python3-pip" ;;
        esac
        INSTALLED+=("python3.12")
    fi
fi

# ---------------------------------------------------------------------------
# 8. Summary + next steps (the user must do these manually)
# ---------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  Summary"
echo "════════════════════════════════════════════════════════════════════════"
[ ${#INSTALLED[@]} -gt 0 ] && { echo "  Installed:"; for x in "${INSTALLED[@]}"; do echo "    + $x"; done; }
[ ${#SKIPPED[@]}   -gt 0 ] && { echo "  Already present:"; for x in "${SKIPPED[@]}"; do echo "    ✓ $x"; done; }
[ ${#MISSING[@]}   -gt 0 ] && { echo "  Still missing (action required):"; for x in "${MISSING[@]}"; do echo "    ✗ $x"; done; }

echo ""
echo "════════════════════════════════════════════════════════════════════════"
echo "  Next steps (this script CANNOT do these for you)"
echo "════════════════════════════════════════════════════════════════════════"
cat <<'EOF'

  1. Authenticate
       az login
       az account set --subscription <your-subscription-id>
       azd auth login                         # if you'll deploy

  2. Verify you have at least 'Reader' role on the resource group where
     your Foundry project lives. Without it, even the read-only discovery
     scripts return empty results that look like 'nothing exists'.

       az role assignment list \
         --assignee $(az ad signed-in-user show --query id -o tsv) \
         --all -o table

     If Reader is missing: ask an Azure subscription Owner or User Access
     Administrator to grant you 'Reader' at the RG scope, or 'Contributor'
     if you'll deploy.

  3. Install the skillpack
       apm install sathik11/foundry-agent-skillpack/foundry-agent-skillpack

  4. Optional caller-side Python deps (only if you'll run /setup-evals,
     /setup-purview, /audit-drift, or the DLP middleware locally)
       pip install "azure-ai-projects>=2.0.0,<3" azure-identity pyyaml httpx

EOF

if [ ${#MISSING[@]} -gt 0 ]; then
    echo "[!] Exiting non-zero because the items above are still missing."
    exit 2
fi
echo "[✓] Prerequisites complete."
