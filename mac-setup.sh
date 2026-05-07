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
XRAY_PORT="443"

###############################################################################
# VALIDATION
###############################################################################
MISSING=()
for var in HOME_IP UUID PUBLIC_KEY SHORT_ID SSH_USER; do
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
# CLASH V-NINJA COMPATIBILITY CHECK (fail-closed, per-condition gate)
###############################################################################
echo "=== Clash V-Ninja compatibility check ==="
echo ""
echo "You must confirm TWO conditions before using Clash V-Ninja directly."
echo "Answer each one individually. If ANY is 'n' or skipped, Scenario B is used."
echo ""

COMPAT_PASS=true

read -rp "1. Does Clash V-Ninja expose a raw YAML config editor (not just GUI forms)? [y/N]: " c1
c1=${c1:-N}
if [[ ! "$c1" =~ ^[Yy]$ ]]; then
    COMPAT_PASS=false
    echo "   → Condition 1 failed. Will use standalone mihomo (Scenario B)."
fi

if $COMPAT_PASS; then
    read -rp "2. Does it accept 'type: vless' and 'dialer-proxy:' in the proxies section? [y/N]: " c2
    c2=${c2:-N}
    if [[ ! "$c2" =~ ^[Yy]$ ]]; then
        COMPAT_PASS=false
        echo "   → Condition 2 failed. Will use standalone mihomo (Scenario B)."
    fi
fi

if $COMPAT_PASS; then
    scenario="A"
    echo ""
    echo "Both conditions confirmed. Using Scenario A (paste config into Clash V-Ninja)."
else
    scenario="B"
    echo ""
    echo "Using Scenario B (install standalone mihomo alongside Clash V-Ninja)."
fi

PROXY_PORT="$MIHOMO_PORT"

###############################################################################
# SCENARIO B — INSTALL + CONFIGURE + START STANDALONE MIHOMO
###############################################################################
if [[ "$scenario" == "B" ]]; then
    STANDALONE_PORT="7891"
    PROXY_PORT="$STANDALONE_PORT"
    echo ""
    echo "=== Installing standalone mihomo ==="

    if ! command -v mihomo &>/dev/null; then
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

sniffer:
  enable: true
  sniff:
    TLS:
      ports: [443, ${XRAY_PORT}]
    HTTP:
      ports: [80]
      override-destination: true

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
  nameserver-policy:
    "+.anthropic.com,+.claude.ai,+.claude.com,+.claudeusercontent.com,+.storage.googleapis.com,+.sentry.io,+.openai.com,+.chatgpt.com": []

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
    dialer-proxy: Clash-V-Ninja-Upstream

proxy-groups:
  - name: AI-via-Home
    type: select
    proxies:
      - Home-USA

  - name: China-VPN
    type: select
    proxies:
      - Clash-V-Ninja-Upstream

rules:
  - DOMAIN-SUFFIX,anthropic.com,AI-via-Home
  - DOMAIN-SUFFIX,claude.ai,AI-via-Home
  - DOMAIN-SUFFIX,claude.com,AI-via-Home
  - DOMAIN-SUFFIX,claudeusercontent.com,AI-via-Home
  - DOMAIN-SUFFIX,storage.googleapis.com,AI-via-Home
  - DOMAIN-SUFFIX,sentry.io,AI-via-Home
  - DOMAIN-SUFFIX,openai.com,AI-via-Home
  - DOMAIN-SUFFIX,chatgpt.com,AI-via-Home
  - IP-CIDR,${HOME_IP}/32,China-VPN,no-resolve
  ## Tier 2 — uncomment as needed (set log-level: debug to discover missing domains)
  # - DOMAIN-SUFFIX,oaistatic.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaiusercontent.com,AI-via-Home
  # - DOMAIN-SUFFIX,intercom.io,AI-via-Home
  # - DOMAIN-SUFFIX,intercomcdn.com,AI-via-Home
  - MATCH,DIRECT
MEOF
    chmod 600 "${MIHOMO_DIR}/config.yaml"
    echo "mihomo config written to ${MIHOMO_DIR}/config.yaml"

    # Create launchd plist for auto-start
    PLIST_DIR="${HOME}/Library/LaunchAgents"
    PLIST_FILE="${PLIST_DIR}/com.mihomo.proxy.plist"
    MIHOMO_BIN=$(command -v mihomo)
    mkdir -p "$PLIST_DIR"

    cat > "$PLIST_FILE" << LEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.mihomo.proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>${MIHOMO_BIN}</string>
        <string>-d</string>
        <string>${MIHOMO_DIR}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${MIHOMO_DIR}/mihomo.log</string>
    <key>StandardErrorPath</key>
    <string>${MIHOMO_DIR}/mihomo.err</string>
</dict>
</plist>
LEOF

    # Stop existing instance if running, then load and start
    launchctl bootout "gui/$(id -u)/com.mihomo.proxy" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_FILE"
    echo "mihomo launchd service installed and started"

    # Verify port is listening
    sleep 2
    if lsof -iTCP:"${STANDALONE_PORT}" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
        echo "mihomo listening on port ${STANDALONE_PORT}"
    else
        echo "WARNING: mihomo port ${STANDALONE_PORT} not yet listening"
        echo "Check logs: cat ${MIHOMO_DIR}/mihomo.err"
    fi

    # Generate PAC file for browser proxy routing
    # Routes all HTTP/HTTPS through mihomo; mihomo's rules handle split routing
    # (AI domains → relay chain, everything else → DIRECT via MATCH rule)
    PAC_FILE="${MIHOMO_DIR}/proxy.pac"
    cat > "$PAC_FILE" << 'PACEOF'
function FindProxyForURL(url, host) {
    if (isPlainHostName(host) ||
        shExpMatch(host, "*.local") ||
        shExpMatch(host, "*.lan") ||
        host === "localhost" ||
        host === "::1") {
        return "DIRECT";
    }
    var ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/;
    var m = host.match(ipv4);
    if (m) {
        var a = parseInt(m[1], 10);
        var b = parseInt(m[2], 10);
        if (a === 127 || a === 10 || a === 0 ||
            (a === 192 && b === 168) ||
            (a === 172 && b >= 16 && b <= 31) ||
            (a === 169 && b === 254)) {
            return "DIRECT";
        }
    }
    if (host.indexOf(":") !== -1) {
        return "DIRECT";
    }
PACEOF
    echo "    return \"PROXY 127.0.0.1:${STANDALONE_PORT}\";" >> "$PAC_FILE"
    echo "}" >> "$PAC_FILE"
    chmod 644 "$PAC_FILE"
    echo "PAC file written to ${PAC_FILE}"

    # Configure macOS system proxy to use PAC file on all active services
    PAC_CONFIGURED=false
    while IFS= read -r svc; do
        [[ -z "$svc" ]] && continue
        # Check if this service has an active IP (i.e., is actually connected)
        if networksetup -getinfo "$svc" 2>/dev/null | grep -q "^IP address: [0-9]"; then
            networksetup -setautoproxyurl "$svc" "file://${PAC_FILE}"
            networksetup -setautoproxystate "$svc" on
            echo "System proxy (PAC) configured for '${svc}'"
            PAC_CONFIGURED=true
        fi
    done < <(networksetup -listallnetworkservices | tail -n +2 | grep -v '^\*')

    if $PAC_CONFIGURED; then
        echo "Browser traffic for AI domains will route through mihomo on port ${STANDALONE_PORT}"
    else
        echo "WARNING: No active network service detected."
        echo "Manually set system proxy PAC URL to: file://${PAC_FILE}"
    fi
fi

###############################################################################
# SCENARIO A — PRINT CONFIG SNIPPETS FOR GUI PASTE (with DNS)
###############################################################################
if [[ "$scenario" == "A" ]]; then
    if [[ -z "$VPN_NODE_NAME" ]]; then
        echo "ERROR: VPN_NODE_NAME is required for Scenario A."
        echo "Set it at the top of this script to your China VPN node name in Clash V-Ninja."
        exit 1
    fi
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
    dialer-proxy: ${VPN_NODE_NAME}
PEOF

    echo ""
    echo "=== 2. Add to 'proxy-groups:' section ==="
    cat << GEOF
  - name: AI-via-Home
    type: select
    proxies:
      - Home-USA
GEOF

    echo ""
    echo "=== 3. Add to 'rules:' section (BEFORE any MATCH rule) ==="
    cat << REOF
  - DOMAIN-SUFFIX,anthropic.com,AI-via-Home
  - DOMAIN-SUFFIX,claude.ai,AI-via-Home
  - DOMAIN-SUFFIX,claude.com,AI-via-Home
  - DOMAIN-SUFFIX,claudeusercontent.com,AI-via-Home
  - DOMAIN-SUFFIX,storage.googleapis.com,AI-via-Home
  - DOMAIN-SUFFIX,sentry.io,AI-via-Home
  - DOMAIN-SUFFIX,openai.com,AI-via-Home
  - DOMAIN-SUFFIX,chatgpt.com,AI-via-Home
  - IP-CIDR,${HOME_IP}/32,${VPN_NODE_NAME},no-resolve
  ## Tier 2 — uncomment as needed (set log-level: debug to discover missing domains)
  # - DOMAIN-SUFFIX,oaistatic.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaiusercontent.com,AI-via-Home
  # - DOMAIN-SUFFIX,intercom.io,AI-via-Home
  # - DOMAIN-SUFFIX,intercomcdn.com,AI-via-Home
REOF

    echo ""
    echo "=== 4. Add/merge into 'dns:' section (for no-leak DNS resolution) ==="
    cat << DEOF
dns:
  enable: true
  enhanced-mode: fake-ip
  fake-ip-range: 198.18.0.1/16
  nameserver:
    - https://dns.google/dns-query
    - https://cloudflare-dns.com/dns-query
  fake-ip-filter:
    - "*.lan"
    - "*.local"
  nameserver-policy:
    "+.anthropic.com,+.claude.ai,+.claude.com,+.claudeusercontent.com,+.storage.googleapis.com,+.sentry.io,+.openai.com,+.chatgpt.com": []
DEOF
    echo ""
    echo "=== 5. Add/merge into top-level config (sniffer for domain detection) ==="
    cat << SNEOF
sniffer:
  enable: true
  sniff:
    TLS:
      ports: [443, ${XRAY_PORT}]
    HTTP:
      ports: [80]
      override-destination: true
SNEOF
fi

###############################################################################
# SSH SETUP (idempotent — updates existing entry on rerun)
###############################################################################
echo ""
echo "=== Setting up SSH ==="
mkdir -p ~/.ssh
chmod 700 ~/.ssh

if [[ ! -f ~/.ssh/id_ed25519 ]]; then
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "$(whoami)@mac"
    echo "Generated SSH key: ~/.ssh/id_ed25519.pub"
fi

SSH_STANZA="Host home
    HostName ${HOME_IP}
    Port ${SSH_PORT}
    User ${SSH_USER}
    ProxyCommand /usr/bin/nc -X connect -x 127.0.0.1:${PROXY_PORT} %h %p
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 5
    ServerAliveCountMax 6
    TCPKeepAlive yes"

touch ~/.ssh/config
chmod 600 ~/.ssh/config

if grep -q "^Host home$" ~/.ssh/config; then
    # Remove existing Host home stanza robustly
    # Skips from "Host home" until the next "Host " or "Match " line or EOF
    awk '
        /^Host home$/ { skip=1; next }
        /^Host / || /^Match / { skip=0 }
        !skip { print }
    ' ~/.ssh/config > ~/.ssh/config.tmp && mv ~/.ssh/config.tmp ~/.ssh/config
    chmod 600 ~/.ssh/config
fi

printf '\n%s\n' "$SSH_STANZA" >> ~/.ssh/config
echo "SSH config 'home' entry written (proxy port: ${PROXY_PORT})"

###############################################################################
# SHELL ALIASES (idempotent — replaces existing block on rerun)
###############################################################################
echo ""
echo "=== Setting up proxy aliases ==="
MARKER_START="# >>> AI CLI proxy aliases — tunnel via home >>>"
MARKER_END="# <<< AI CLI proxy aliases <<<"

ALIAS_BLOCK="${MARKER_START}
alias claude='NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT} HTTP_PROXY=http://127.0.0.1:${PROXY_PORT} claude'
alias openai='NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 HTTPS_PROXY=http://127.0.0.1:${PROXY_PORT} HTTP_PROXY=http://127.0.0.1:${PROXY_PORT} openai'
${MARKER_END}"

touch ~/.zshrc
if grep -qF "$MARKER_START" ~/.zshrc; then
    # Remove old block and replace
    sed -i '' "/${MARKER_START//\//\\/}/,/${MARKER_END//\//\\/}/d" ~/.zshrc
fi

printf '\n%s\n' "$ALIAS_BLOCK" >> ~/.zshrc
echo "Proxy aliases written to ~/.zshrc (port: ${PROXY_PORT})"

###############################################################################
# NEXT STEPS
###############################################################################
echo ""
echo "============================================================"
echo "  MAC SETUP COMPLETE"
echo "============================================================"
echo ""
if [[ "$scenario" == "A" ]]; then
    echo "  1. Paste ALL config snippets above into Clash V-Ninja GUI"
    echo "     (proxies, proxy-groups, rules, dns, AND sniffer sections)"
elif [[ "$scenario" == "B" ]]; then
    echo "  1. mihomo is running on port ${STANDALONE_PORT} (auto-starts on login)"
    echo "     Browser traffic for AI domains is routed via system PAC proxy"
fi
echo "  2. Copy SSH key to home laptop:"
echo "     ssh-copy-id -p ${SSH_PORT} ${SSH_USER}@${HOME_IP}"
echo "     (route through China VPN or use physical access)"
echo "  3. Test SSH: ssh home"
echo "     If SSH logs in and then drops after ~20s, confirm ServerAliveInterval is 5"
echo "  4. Test tunnel routing (should succeed through home IP):"
echo "     curl --proxy http://127.0.0.1:${PROXY_PORT} -sI https://claude.ai 2>&1 | head -5"
echo "     (should get HTTP response, not connection refused)"
echo "  5. Restart terminal or run: source ~/.zshrc"
echo "  6. Test Claude: claude --version"
echo ""
echo "  If domains are missing, set log-level: debug in mihomo/Clash V-Ninja"
echo "  and check logs for blocked connections. Uncomment Tier 2 rules as needed."
echo "============================================================"
