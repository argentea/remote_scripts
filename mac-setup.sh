#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# mac-setup.sh — 1-shot setup for tunnel client on Mac
# Run on: Mac at Chinese corporate office
# Usage:  bash mac-setup.sh
###############################################################################

###############################################################################
# CONFIG — fill in from home-setup.sh output
###############################################################################
HOME_IP=""
UUID=""
PUBLIC_KEY=""
SHORT_ID=""
SSH_PORT="22222"
SSH_USER=""
VPN_NODE_NAME=""
MIHOMO_PORT="7890"
XRAY_PORT="41792"

###############################################################################
# VALIDATION
###############################################################################
MISSING=()
for var in HOME_IP UUID PUBLIC_KEY SHORT_ID SSH_USER VPN_NODE_NAME; do
    if [[ -z "${!var}" ]]; then
        MISSING+=("$var")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: Fill in these config values at the top of this script:"
    printf '  - %s\n' "${MISSING[@]}"
    echo ""
    echo "Get these values from home-setup.sh output or /root/mac-setup-values.txt"
    exit 1
fi

REALITY_SNI="www.microsoft.com"

###############################################################################
# CLASH V-NINJA COMPATIBILITY CHECK
###############################################################################
echo "=== Clash V-Ninja compatibility check ==="
echo ""
echo "This script needs to know if your Clash V-Ninja app supports"
echo "VLESS+REALITY proxies and relay proxy groups."
echo ""
echo "  [A] Clash V-Ninja supports VLESS + relay (mihomo/Clash.Meta core)"
echo "      → Config snippets will be printed for you to paste into the GUI"
echo ""
echo "  [B] Clash V-Ninja does NOT support these features (original Clash core)"
echo "      → A standalone mihomo instance will be installed alongside it"
echo ""
read -rp "Choose [A/B]: " scenario
scenario=${scenario^^}

if [[ "$scenario" != "A" && "$scenario" != "B" ]]; then
    echo "ERROR: Choose A or B"
    exit 1
fi

PROXY_PORT="$MIHOMO_PORT"

###############################################################################
# SCENARIO B — INSTALL STANDALONE MIHOMO
###############################################################################
if [[ "$scenario" == "B" ]]; then
    STANDALONE_PORT="7891"
    PROXY_PORT="$STANDALONE_PORT"
    echo ""
    echo "=== Installing standalone mihomo ==="

    if ! command -v mihomo &>/dev/null; then
        echo "Installing mihomo via Homebrew..."
        if ! command -v brew &>/dev/null; then
            echo "ERROR: Homebrew not found. Install from https://brew.sh"
            exit 1
        fi
        brew install mihomo
    else
        echo "mihomo already installed: $(mihomo -v 2>&1 | head -1)"
    fi

    MIHOMO_DIR="${HOME}/.config/mihomo"
    mkdir -p "$MIHOMO_DIR"

    cat > "${MIHOMO_DIR}/config.yaml" << MEOF
mixed-port: ${STANDALONE_PORT}
mode: rule
log-level: info
allow-lan: false

dns:
  enable: true
  listen: 127.0.0.1:1053
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
  fake-ip-filter:
    - "*.lan"
    - "*.local"

proxies:
  - name: Clash-V-Ninja-Upstream
    type: http
    server: 127.0.0.1
    port: ${MIHOMO_PORT}

  - name: Home-USA
    type: vless
    server: ${HOME_IP}
    port: ${XRAY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome
    skip-cert-verify: false

proxy-groups:
  - name: AI-via-Home
    type: relay
    proxies:
      - Clash-V-Ninja-Upstream
      - Home-USA

  - name: China-VPN
    type: select
    proxies:
      - Clash-V-Ninja-Upstream

rules:
  # AI domains → relay through home
  - DOMAIN-SUFFIX,anthropic.com,AI-via-Home
  - DOMAIN-SUFFIX,claude.ai,AI-via-Home
  - DOMAIN-SUFFIX,openai.com,AI-via-Home
  - DOMAIN-SUFFIX,chatgpt.com,AI-via-Home
  # SSH routing → direct through China VPN
  - IP-CIDR,${HOME_IP}/32,China-VPN,no-resolve
  ## Tier 2 — uncomment as needed (set log-level: debug to discover missing domains)
  # - DOMAIN-SUFFIX,claude.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaistatic.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaiusercontent.com,AI-via-Home
  # - DOMAIN-SUFFIX,sentry.io,AI-via-Home
  # - DOMAIN-SUFFIX,statsig.anthropic.com,AI-via-Home
  # - DOMAIN-SUFFIX,intercom.io,AI-via-Home
  # - DOMAIN-SUFFIX,intercomcdn.com,AI-via-Home
  # Everything else → direct (Clash V-Ninja handles GFW bypass separately)
  - MATCH,DIRECT
MEOF

    chmod 600 "${MIHOMO_DIR}/config.yaml"
    echo "mihomo config written to ${MIHOMO_DIR}/config.yaml"
    echo "Standalone mihomo listens on port ${STANDALONE_PORT}"
    echo ""
    echo "To start mihomo:"
    echo "  mihomo -d ${MIHOMO_DIR}"
    echo ""
    echo "To run as a background service (launchd), create a plist or use:"
    echo "  brew services start mihomo"
fi

###############################################################################
# SCENARIO A — PRINT CONFIG SNIPPETS FOR GUI PASTE
###############################################################################
if [[ "$scenario" == "A" ]]; then
    echo ""
    echo "============================================================"
    echo "  PASTE THE FOLLOWING INTO CLASH V-NINJA"
    echo "============================================================"
    echo ""
    echo "=== 1. Add to 'proxies:' section ==="
    cat << PEOF
  - name: Home-USA
    type: vless
    server: ${HOME_IP}
    port: ${XRAY_PORT}
    uuid: ${UUID}
    network: tcp
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    reality-opts:
      public-key: ${PUBLIC_KEY}
      short-id: ${SHORT_ID}
    client-fingerprint: chrome
    skip-cert-verify: false
PEOF

    echo ""
    echo "=== 2. Add to 'proxy-groups:' section ==="
    cat << GEOF
  - name: AI-via-Home
    type: relay
    proxies:
      - ${VPN_NODE_NAME}
      - Home-USA
GEOF

    echo ""
    echo "=== 3. Add to 'rules:' section (BEFORE any MATCH rule) ==="
    cat << REOF
  # Tier 1 — required for CLI and API
  - DOMAIN-SUFFIX,anthropic.com,AI-via-Home
  - DOMAIN-SUFFIX,claude.ai,AI-via-Home
  - DOMAIN-SUFFIX,openai.com,AI-via-Home
  - DOMAIN-SUFFIX,chatgpt.com,AI-via-Home
  # SSH routing — direct to China VPN, not through relay
  - IP-CIDR,${HOME_IP}/32,${VPN_NODE_NAME},no-resolve
  ## Tier 2 — uncomment as needed (set log-level: debug to discover missing domains)
  # - DOMAIN-SUFFIX,claude.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaistatic.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaiusercontent.com,AI-via-Home
  # - DOMAIN-SUFFIX,sentry.io,AI-via-Home
  # - DOMAIN-SUFFIX,statsig.anthropic.com,AI-via-Home
  # - DOMAIN-SUFFIX,intercom.io,AI-via-Home
  # - DOMAIN-SUFFIX,intercomcdn.com,AI-via-Home
REOF
fi

###############################################################################
# SSH SETUP
###############################################################################
echo ""
echo "=== Setting up SSH ==="
mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "$(whoami)@mac"
    echo "Generated SSH key: ~/.ssh/id_ed25519.pub"
fi

if [[ -f ~/.ssh/config ]] && grep -q "^Host home$" ~/.ssh/config; then
    echo "SSH config 'home' entry already exists — skipping"
else
    cat >> ~/.ssh/config << SEOF

Host home
    HostName ${HOME_IP}
    Port ${SSH_PORT}
    User ${SSH_USER}
    ProxyCommand /usr/bin/nc -X connect -x 127.0.0.1:${PROXY_PORT} %h %p
    IdentityFile ~/.ssh/id_ed25519
SEOF
    chmod 600 ~/.ssh/config
    echo "Added 'home' entry to ~/.ssh/config (proxy port: ${PROXY_PORT})"
fi

###############################################################################
# SHELL ALIASES
###############################################################################
echo ""
echo "=== Setting up proxy aliases ==="
MARKER="# AI CLI proxy aliases — tunnel via home"

if grep -qF "$MARKER" ~/.zshrc 2>/dev/null; then
    echo "Proxy aliases already in ~/.zshrc — skipping"
else
    cat >> ~/.zshrc << AEOF

${MARKER}
alias claude='HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT} HTTP_PROXY=http://127.0.0.1:${PROXY_PORT} claude'
alias openai='HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT} HTTP_PROXY=http://127.0.0.1:${PROXY_PORT} openai'
AEOF
    echo "Added proxy aliases to ~/.zshrc (port: ${PROXY_PORT})"
fi

###############################################################################
# NEXT STEPS
###############################################################################
echo ""
echo "============================================================"
echo "  MAC SETUP COMPLETE"
echo "============================================================"
echo ""
if [[ "$scenario" == "A" ]]; then
    echo "  1. Paste the config snippets above into Clash V-Ninja GUI"
elif [[ "$scenario" == "B" ]]; then
    echo "  1. Start mihomo: mihomo -d ~/.config/mihomo"
    echo "     (or: brew services start mihomo)"
fi
echo "  2. Copy SSH key to home laptop:"
echo "     ssh-copy-id -p ${SSH_PORT} ${SSH_USER}@${HOME_IP}"
echo "     (route through China VPN or use physical access)"
echo "  3. Test SSH: ssh home"
echo "  4. Test tunnel exit IP:"
echo "     curl --proxy http://127.0.0.1:${PROXY_PORT} https://ifconfig.me"
echo "     (should return: ${HOME_IP})"
echo "  5. Restart terminal or run: source ~/.zshrc"
echo "  6. Test Claude: claude --version"
echo ""
echo "  If domains are missing, set log-level: debug in mihomo/Clash V-Ninja"
echo "  and check logs for blocked connections. Uncomment Tier 2 rules as needed."
echo "============================================================"
