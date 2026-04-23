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

###############################################################################
# PRE-FLIGHT
###############################################################################
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run as root: sudo bash $0"
    exit 1
fi

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
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

###############################################################################
# GENERATE CREDENTIALS
###############################################################################
echo ""
echo "=== Generating credentials ==="
UUID=$(xray uuid)
KEYS=$(xray x25519)
PRIVATE_KEY=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
PUBLIC_KEY=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')
SHORT_ID=$(openssl rand -hex 4)

echo "UUID:        ${UUID}"
echo "Public Key:  ${PUBLIC_KEY}"
echo "Short ID:    ${SHORT_ID}"

###############################################################################
# WRITE XRAY CONFIG
###############################################################################
echo ""
echo "=== Writing xray config ==="
mkdir -p /usr/local/etc/xray
mkdir -p /var/log/xray

cat > /usr/local/etc/xray/config.json << XEOF
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

chown nobody:nogroup /usr/local/etc/xray/config.json 2>/dev/null \
    || chown nobody:nobody /usr/local/etc/xray/config.json
chmod 600 /usr/local/etc/xray/config.json

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
    echo "xray service: active"
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

systemctl restart systemd-logind
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true
echo "Lid-close ignored; sleep/suspend/hibernate masked"

###############################################################################
# UFW FIREWALL
###############################################################################
echo ""
echo "=== Configuring UFW ==="
ufw allow "${XRAY_PORT}/tcp" comment 'Xray VLESS+REALITY'
ufw allow "${SSH_PORT}/tcp" comment 'SSH non-standard'
ufw allow 22/tcp comment 'SSH standard — remove after confirming non-standard port works'
ufw --force enable
echo ""
ufw status numbered

###############################################################################
# SSH — NON-STANDARD PORT
###############################################################################
echo ""
echo "=== Configuring SSH ==="
SSHD_CFG=/etc/ssh/sshd_config

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
systemctl restart sshd || systemctl restart ssh
echo "SSH listening on ports 22 and ${SSH_PORT}"
echo ""
echo ">>> SSH HARDENING (do this after setting up SSH keys):"
echo ">>>   1. Copy your public key: ssh-copy-id -p ${SSH_PORT} user@${PUBLIC_IP}"
echo ">>>   2. Edit ${SSHD_CFG}: remove 'Port 22', set 'PasswordAuthentication no'"
echo ">>>   3. Run: sudo ufw delete allow 22/tcp"
echo ">>>   4. Run: sudo systemctl restart sshd"
echo ""
echo ">>> NOTE: SSH key bootstrap requires physical access or temporary"
echo ">>>       password auth before the tunnel is operational."

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
