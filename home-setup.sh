#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# home-setup.sh — 1-shot setup for Xray VLESS+REALITY+Vision server
# Run on: Home Ubuntu laptop (USA)
# Usage:  sudo bash home-setup.sh
###############################################################################

###############################################################################
# CONFIG
###############################################################################
XRAY_PORT=41792
SSH_PORT=22222
REALITY_DEST="www.microsoft.com:443"
REALITY_SNI="www.microsoft.com"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

###############################################################################
# PARSE FLAGS
###############################################################################
ROTATE_CREDS=false
SSH_PUBKEY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --rotate)
            ROTATE_CREDS=true
            shift
            ;;
        --ssh-pubkey)
            SSH_PUBKEY="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: sudo bash $0 [--rotate] [--ssh-pubkey <key-string>]"
            exit 1
            ;;
    esac
done

###############################################################################
# PRE-FLIGHT
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo bash $0"
    exit 1
fi

echo "=== Installing dependencies ==="
apt-get update -qq
apt-get install -y -qq curl openssh-server ufw openssl iproute2 procps > /dev/null
mkdir -p /run/sshd
systemctl enable ssh
echo "Dependencies installed"

echo ""
echo "=== Pre-flight checks ==="

PUBLIC_IP=$(curl -s4 --max-time 10 ifconfig.me || true)
if [[ -z "$PUBLIC_IP" ]]; then
    echo "ERROR: Could not detect public IP. Check internet connectivity."
    exit 1
fi

LAN_IP=$(hostname -I | awk '{print $1}')
echo "Public IP: ${PUBLIC_IP}"
echo "LAN IP:    ${LAN_IP}"
echo ""
echo ">>> CGNAT CHECK:"
echo ">>> Log into your router and compare its WAN IP to ${PUBLIC_IP}"
echo ">>> If they differ (e.g., router WAN is 10.x.x.x or 100.64-127.x.x.x),"
echo ">>> you are behind CGNAT and port forwarding will NOT work."
echo ""
read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || exit 0

###############################################################################
# INSTALL XRAY-CORE
###############################################################################
echo ""
echo "=== Installing xray-core ==="
if command -v xray &>/dev/null; then
    echo "xray already installed: $(xray version | head -1)"
else
    # Pin to a known commit for supply-chain safety
    XRAY_INSTALL_COMMIT="e741a4f56d368afbb9e5be3361b40c4552d3710d"
    XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/${XRAY_INSTALL_COMMIT}/install-release.sh"

    TMPSCRIPT=$(mktemp)
    curl -fsSL "$XRAY_INSTALL_URL" -o "$TMPSCRIPT"

    # Verify the script was downloaded successfully
    if [[ ! -s "$TMPSCRIPT" ]]; then
        echo "ERROR: Failed to download Xray install script"
        rm -f "$TMPSCRIPT"
        exit 1
    fi

    bash "$TMPSCRIPT" install
    rm -f "$TMPSCRIPT"
fi

###############################################################################
# CREDENTIALS — reuse existing or generate new
###############################################################################
echo ""
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

if [[ -f "$XRAY_CONFIG" ]] && ! $ROTATE_CREDS; then
    echo "=== Reusing existing Xray credentials ==="
    UUID=$(grep -o '"id": *"[^"]*"' "$XRAY_CONFIG" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    PRIVATE_KEY=$(grep -o '"privateKey": *"[^"]*"' "$XRAY_CONFIG" | head -1 | sed 's/.*"\([^"]*\)"/\1/')
    SHORT_ID=$(grep -o '"shortIds": *\["[^"]*"\]' "$XRAY_CONFIG" | head -1 | sed 's/.*\["\([^"]*\)"\]/\1/')
    PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" 2>/dev/null | grep -i "public" | awk '{print $NF}')

    if [[ -z "$UUID" || -z "$PRIVATE_KEY" || -z "$SHORT_ID" || -z "$PUBLIC_KEY" ]]; then
        echo "WARNING: Could not extract credentials from existing config. Generating new ones."
        ROTATE_CREDS=true
    else
        echo "UUID:        ${UUID}"
        echo "Public Key:  ${PUBLIC_KEY}"
        echo "Short ID:    ${SHORT_ID}"
        echo "(Use --rotate to generate fresh credentials)"
    fi
fi

if [[ ! -f "$XRAY_CONFIG" ]] || $ROTATE_CREDS; then
    echo "=== Generating new credentials ==="
    UUID=$(xray uuid)
    KEYS=$(xray x25519)
    PRIVATE_KEY=$(echo "$KEYS" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYS" | grep -i "public" | awk '{print $NF}')
    SHORT_ID=$(openssl rand -hex 4)

    echo "UUID:        ${UUID}"
    echo "Public Key:  ${PUBLIC_KEY}"
    echo "Short ID:    ${SHORT_ID}"
fi

###############################################################################
# WRITE XRAY CONFIG
###############################################################################
echo ""
echo "=== Writing xray config ==="

cat > "$XRAY_CONFIG" << XEOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "serverNames": ["${REALITY_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ]
}
XEOF

chown nobody:nogroup "$XRAY_CONFIG" 2>/dev/null \
    || chown nobody:nobody "$XRAY_CONFIG"
chmod 600 "$XRAY_CONFIG"

###############################################################################
# SYSTEMD SERVICE
###############################################################################
echo ""
echo "=== Configuring xray systemd service ==="

if [[ ! -f /etc/systemd/system/xray.service ]]; then
    cat > /etc/systemd/system/xray.service << 'SEOF'
[Unit]
Description=Xray Service
Documentation=https://xtls.github.io
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
RestartSec=5
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SEOF
else
    sed -i 's/^Restart=.*/Restart=always/' /etc/systemd/system/xray.service
    if ! grep -q '^RestartSec=' /etc/systemd/system/xray.service; then
        sed -i '/^Restart=/a RestartSec=5' /etc/systemd/system/xray.service
    fi
fi

chown nobody:nogroup /var/log/xray 2>/dev/null || chown nobody:nobody /var/log/xray
chmod 750 /var/log/xray

systemctl daemon-reload
systemctl enable xray
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
    echo "xray service: active (Restart=always — restarts on crash, auto-starts on boot)"
    echo "  Test: sudo kill -9 \$(pidof xray) → service should restart within 5s"
else
    echo "ERROR: xray service failed to start"
    systemctl status xray --no-pager
    exit 1
fi

if ss -tlnp | grep -q ":${XRAY_PORT}\b"; then
    echo "xray listening on port ${XRAY_PORT}"
else
    echo "ERROR: port ${XRAY_PORT} not listening"
    exit 1
fi

###############################################################################
# ANTI-SLEEP
###############################################################################
echo ""
echo "=== Configuring anti-sleep ==="
LOGIND=/etc/systemd/logind.conf

for key in HandleLidSwitch HandleLidSwitchExternalPower HandleLidSwitchDocked; do
    if grep -q "^#\?${key}=" "$LOGIND"; then
        sed -i "s/^#\?${key}=.*/${key}=ignore/" "$LOGIND"
    else
        echo "${key}=ignore" >> "$LOGIND"
    fi
done

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
echo "Lid-close settings written; sleep/suspend/hibernate masked"
echo "  NOTE: logind.conf changes take effect after reboot (or: systemctl restart systemd-logind)"

###############################################################################
# UFW FIREWALL
###############################################################################
echo ""
echo "=== Configuring UFW ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow "${XRAY_PORT}/tcp" comment 'Xray VLESS+REALITY'
ufw allow "${SSH_PORT}/tcp" comment 'SSH non-standard'
ufw allow 22/tcp comment 'SSH standard — TEMPORARY: remove after confirming non-standard port + key auth'
ufw --force enable
echo ""
ufw status verbose

###############################################################################
# SSH — NON-STANDARD PORT + HARDENING
###############################################################################
echo ""
echo "=== Configuring SSH ==="
SSHD_CFG=/etc/ssh/sshd_config
REAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo root)}
REAL_HOME=$(eval echo "~${REAL_USER}")
AUTHORIZED_KEYS="${REAL_HOME}/.ssh/authorized_keys"

# Ensure non-standard port is configured
if ! grep -q "^Port ${SSH_PORT}" "$SSHD_CFG"; then
    if grep -q "^Port " "$SSHD_CFG"; then
        sed -i "/^Port /a Port ${SSH_PORT}" "$SSHD_CFG"
    elif grep -q "^#Port " "$SSHD_CFG"; then
        sed -i "s/^#Port .*/Port 22\nPort ${SSH_PORT}/" "$SSHD_CFG"
    else
        echo "Port 22" >> "$SSHD_CFG"
        echo "Port ${SSH_PORT}" >> "$SSHD_CFG"
    fi
fi
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CFG"

# Ensure .ssh directory and authorized_keys exist
mkdir -p "${REAL_HOME}/.ssh"
touch "$AUTHORIZED_KEYS"
chmod 700 "${REAL_HOME}/.ssh"
chmod 600 "$AUTHORIZED_KEYS"
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.ssh"

# Install SSH public key if provided via --ssh-pubkey or interactive paste
HAS_KEY=false
if [[ -n "$SSH_PUBKEY" ]]; then
    if ! grep -qF "$SSH_PUBKEY" "$AUTHORIZED_KEYS"; then
        echo "$SSH_PUBKEY" >> "$AUTHORIZED_KEYS"
        echo "SSH public key installed from --ssh-pubkey flag"
    else
        echo "SSH public key already present in authorized_keys"
    fi
    HAS_KEY=true
elif [[ -f "$AUTHORIZED_KEYS" ]] && [[ -s "$AUTHORIZED_KEYS" ]]; then
    HAS_KEY=true
    echo "Existing SSH keys found in authorized_keys"
else
    echo ""
    echo "No SSH public key found. You can paste your Mac's public key now,"
    echo "or press Enter to skip (port 22 will remain open temporarily)."
    echo ""
    read -rp "Paste Mac SSH public key (or Enter to skip): " PASTED_KEY
    if [[ -n "$PASTED_KEY" ]]; then
        echo "$PASTED_KEY" >> "$AUTHORIZED_KEYS"
        echo "SSH public key installed"
        HAS_KEY=true
    fi
fi

# Harden SSH if we have a key, or leave port 22 open as temporary bootstrap
if $HAS_KEY; then
    sed -i '/^Port 22$/d' "$SSHD_CFG"

    # Disable all password-like authentication methods
    for directive in PasswordAuthentication KbdInteractiveAuthentication ChallengeResponseAuthentication; do
        if grep -q "^#\?${directive}" "$SSHD_CFG"; then
            sed -i "s/^#\?${directive}.*/${directive} no/" "$SSHD_CFG"
        else
            echo "${directive} no" >> "$SSHD_CFG"
        fi
    done

    # Validate sshd config before restarting
    if sshd -t 2>/dev/null; then
        systemctl restart sshd || systemctl restart ssh
    else
        echo "ERROR: sshd config validation failed:"
        sshd -t
        exit 1
    fi

    # Remove UFW rule noninteractively
    yes | ufw delete allow 22/tcp 2>/dev/null || true
    echo "SSH hardening complete: port 22 closed, all password auth disabled"
    echo "SSH listening on port ${SSH_PORT} only (key-based auth)"
else
    systemctl restart sshd || systemctl restart ssh
    echo ""
    echo "WARNING: SSH hardening NOT complete (AC-10 not satisfied)"
    echo "  Port 22 is open and password auth is enabled as a temporary bootstrap."
    echo "  To finish hardening, rerun with: sudo bash $0 --ssh-pubkey '<your-key>'"
    echo "  Or: ssh-copy-id -p ${SSH_PORT} ${REAL_USER}@${PUBLIC_IP}"
    echo "       then: sudo bash $0"
fi

###############################################################################
# HEALTH CHECK
###############################################################################
echo ""
echo "=== Setting up health check ==="

cat > /usr/local/bin/xray-health-check.sh << 'HEOF'
#!/usr/bin/env bash
set -euo pipefail
PORT=41792
OK=true
MSG=""

if ! pgrep -x xray >/dev/null; then
    OK=false; MSG="process not running"
elif ! ss -tlnp | grep -q ":${PORT}\b"; then
    OK=false; MSG="port ${PORT} not listening"
else
    CURRENT_IP=$(curl -s --max-time 5 ifconfig.me || echo "")
    if [[ -z "$CURRENT_IP" ]]; then
        OK=false; MSG="outbound connectivity failed"
    else
        echo "OK (public IP: ${CURRENT_IP})"
        exit 0
    fi
fi

echo "FAIL: ${MSG}"
exit 1
HEOF
chmod +x /usr/local/bin/xray-health-check.sh

cat > /etc/systemd/system/xray-health.service << 'HSEOF'
[Unit]
Description=Xray health check

[Service]
Type=oneshot
ExecStart=/usr/local/bin/xray-health-check.sh
HSEOF

cat > /etc/systemd/system/xray-health.timer << 'HTEOF'
[Unit]
Description=Run Xray health check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
HTEOF

systemctl daemon-reload
systemctl enable --now xray-health.timer
echo "Health check timer active — view: journalctl -u xray-health"

###############################################################################
# SSH KEY PERMISSIONS — final verification
###############################################################################
chown -R "${REAL_USER}:${REAL_USER}" "${REAL_HOME}/.ssh"
chmod 600 "$AUTHORIZED_KEYS"

###############################################################################
# SECRETS.MD — document credential generation procedure
###############################################################################
echo ""
echo "=== Generating SECRETS.md ==="
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SECRETS_FILE="${SCRIPT_DIR}/SECRETS.md"
cat > "$SECRETS_FILE" << SDEOF
# Credential Generation Procedure

Generated by home-setup.sh on $(date -Iseconds)

## Xray UUID
Command: \`xray uuid\`
Value: ${UUID}

## REALITY x25519 Keypair
Command: \`xray x25519\`
Public Key: ${PUBLIC_KEY}
Private Key: stored in ${XRAY_CONFIG} (chmod 600)

## REALITY Short ID
Command: \`openssl rand -hex 4\`
Value: ${SHORT_ID}

## SSH Keys
Generated on Mac client via: \`ssh-keygen -t ed25519\`
Authorized keys file: ${REAL_HOME}/.ssh/authorized_keys (chmod 600)

## File Permissions
- ${XRAY_CONFIG}: 600, owned by nobody
- ${REAL_HOME}/.ssh/authorized_keys: 600, owned by ${REAL_USER}
- /root/mac-setup-values.txt: 600, owned by root — DELETE after Mac setup

## Regeneration
To rotate credentials: sudo bash home-setup.sh --rotate
Then update mac-setup.sh config block and Clash V-Ninja config with new values.
SDEOF
chmod 600 "$SECRETS_FILE"
echo "SECRETS.md written to ${SECRETS_FILE} (chmod 600, gitignored)"

###############################################################################
# SAVE VALUES
###############################################################################
VALUES_FILE=/root/mac-setup-values.txt
cat > "$VALUES_FILE" << VEOF
# Generated by home-setup.sh — $(date -Iseconds)
# Copy these into mac-setup.sh config block, then DELETE this file.

HOME_IP="${PUBLIC_IP}"
UUID="${UUID}"
PUBLIC_KEY="${PUBLIC_KEY}"
SHORT_ID="${SHORT_ID}"
SSH_PORT="${SSH_PORT}"
XRAY_PORT="${XRAY_PORT}"
VEOF
chmod 600 "$VALUES_FILE"

###############################################################################
# OUTPUT — SUMMARY + MIHOMO SNIPPETS
###############################################################################
echo ""
echo "============================================================"
echo "  HOME SETUP COMPLETE"
echo "============================================================"
echo ""
echo "  Home public IP:  ${PUBLIC_IP}"
echo "  Xray port:       ${XRAY_PORT}"
echo "  SSH port:        ${SSH_PORT}"
echo "  UUID:            ${UUID}"
echo "  REALITY pubkey:  ${PUBLIC_KEY}"
echo "  Short ID:        ${SHORT_ID}"
echo ""
echo "  Values saved to: ${VALUES_FILE}"
echo "  >>> DELETE this file after configuring the Mac."
echo ""
echo "============================================================"
echo "  MIHOMO CONFIG SNIPPETS (paste into Clash V-Ninja)"
echo "============================================================"
echo ""
echo "=== 1. Add to 'proxies:' section ==="
cat << PEOF
  - name: Home-USA
    type: vless
    server: ${PUBLIC_IP}
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
cat << 'GEOF'
  - name: AI-via-Home
    type: relay
    proxies:
      - <YOUR-CHINA-VPN-NODE-NAME>    # first hop: get through GFW
      - Home-USA                       # second hop: exit via home IP
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
  - IP-CIDR,${PUBLIC_IP}/32,<YOUR-CHINA-VPN-NODE-NAME>,no-resolve
  ## Tier 2 — uncomment as needed (use log-level: debug to discover missing domains)
  # - DOMAIN-SUFFIX,claude.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaistatic.com,AI-via-Home
  # - DOMAIN-SUFFIX,oaiusercontent.com,AI-via-Home
  # - DOMAIN-SUFFIX,sentry.io,AI-via-Home
  # - DOMAIN-SUFFIX,statsig.anthropic.com,AI-via-Home
  # - DOMAIN-SUFFIX,intercom.io,AI-via-Home
  # - DOMAIN-SUFFIX,intercomcdn.com,AI-via-Home
REOF

echo ""
echo "============================================================"
echo "  MANUAL STEPS REMAINING"
echo "============================================================"
echo ""
echo "  1. Router: forward TCP ${XRAY_PORT} → ${LAN_IP}:${XRAY_PORT}"
echo "  2. Router: forward TCP ${SSH_PORT}  → ${LAN_IP}:${SSH_PORT}"
echo "  3. Router: set DHCP reservation for ${LAN_IP}"
echo "  4. Test from phone (cellular): nc -zv ${PUBLIC_IP} ${XRAY_PORT}"
echo ""
echo "  Then run mac-setup.sh on your Mac."
echo "============================================================"
