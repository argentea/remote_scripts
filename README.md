# Remote Scripts — AI Tunnel Setup

Route Claude and OpenAI traffic from a Mac in a Chinese corporate office through a home Ubuntu laptop in the USA, bypassing regional restrictions.

## Architecture

```
Mac (China office)
  → Clash V-Ninja (port 7890, China VPN)
    → Home Ubuntu laptop (USA, port 41792, Xray VLESS+REALITY+Vision)
      → claude.ai / openai.com / chatgpt.com
```

- **VLESS+REALITY+Vision**: Xray protocol that mimics a real TLS handshake to `www.microsoft.com:443`, making the traffic indistinguishable from normal HTTPS
- **Relay proxy chain**: Traffic goes Mac → China VPN (first hop, exits the firewall) → Home Xray (second hop, exits with a US IP)
- **Split routing**: Only AI domains go through the tunnel; everything else goes direct

## Files

| File | Run on | Purpose |
|------|--------|---------|
| `home-setup.sh` | Ubuntu laptop (USA) | Installs Xray, configures firewall, SSH hardening, anti-sleep, health checks |
| `mac-setup.sh` | Mac (China office) | Configures proxy chain, SSH tunnel, CLI aliases |

## Prerequisites

### Home Ubuntu Laptop
- Ubuntu 20.04+ with root access
- Public IP (not behind CGNAT — router WAN IP must match public IP)
- Router admin access for port forwarding

### Mac
- Homebrew installed
- Clash V-Ninja running with a working China VPN connection
- Terminal access

## Deployment

### Step 1: Generate SSH Key on Mac

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
```

Skip if you already have `~/.ssh/id_ed25519`.

### Step 2: Run home-setup.sh on Ubuntu Laptop

Copy `home-setup.sh` to the laptop (USB, scp, etc.), then:

```bash
sudo bash home-setup.sh --ssh-pubkey "$(cat ~/.ssh/id_ed25519.pub)"
```

The script will:
1. Ask you to confirm a CGNAT check — compare the printed public IP with your router's WAN IP. Type `y` if they match.
2. Install Xray (pinned to a known-good commit)
3. Generate credentials (UUID, REALITY keys, shortId)
4. Write Xray config and start the systemd service
5. Disable lid-close sleep and mask suspend/hibernate
6. Configure UFW firewall (deny all incoming, allow 41792 + 22222)
7. Harden SSH (key-only auth, non-standard port, all password methods disabled)
8. Set up a 5-minute health check timer
9. Print all values needed for the Mac setup

Save the printed values. They are also stored in `/root/mac-setup-values.txt`.

#### home-setup.sh Flags

| Flag | Purpose |
|------|---------|
| `--ssh-pubkey "<key>"` | Install Mac's public key and complete SSH hardening in one pass |
| `--rotate` | Force-regenerate all credentials (breaks existing Mac client — update mac-setup.sh after) |

#### What It Changes

| File / Setting | Change |
|----------------|--------|
| `/usr/local/bin/xray` | Xray binary installed |
| `/usr/local/etc/xray/config.json` | VLESS+REALITY server config (chmod 600) |
| `/etc/systemd/system/xray.service` | Systemd unit with Restart=always |
| `/etc/systemd/logind.conf` | HandleLidSwitch=ignore (3 directives) |
| sleep/suspend/hibernate targets | Masked |
| UFW rules | Default deny incoming; allow 41792/tcp, 22222/tcp |
| `/etc/ssh/sshd_config` | Port 22222, key-only auth, password auth disabled |
| `~user/.ssh/authorized_keys` | Mac's SSH public key |
| `/usr/local/bin/xray-health-check.sh` | Health check script |
| `/etc/systemd/system/xray-health.timer` | 5-minute health check timer |
| `SECRETS.md` (in script directory) | Credential documentation (chmod 600, gitignored) |
| `/root/mac-setup-values.txt` | Values for mac-setup.sh (chmod 600) |

### Step 3: Configure Router

Log into your router admin panel:

1. **Port forward** TCP 41792 → laptop's LAN IP:41792
2. **Port forward** TCP 22222 → laptop's LAN IP:22222
3. **DHCP reservation** — bind the laptop's LAN IP so it doesn't change

The LAN IP is printed by `home-setup.sh`.

### Step 4: Test External Reachability

From your phone on **cellular data** (not home Wi-Fi):

```bash
nc -zv <HOME_IP> 41792    # Xray port
nc -zv <HOME_IP> 22222    # SSH port
```

Both should report "Connection succeeded."

### Step 5: Edit mac-setup.sh

On your Mac, fill in the config block at the top of `mac-setup.sh`:

```bash
HOME_IP="<public IP from Step 2>"
UUID="<from Step 2 output>"
PUBLIC_KEY="<from Step 2 output>"
SHORT_ID="<from Step 2 output>"
SSH_PORT="22222"
SSH_USER="<your ubuntu username>"
VPN_NODE_NAME=""          # only needed if Clash V-Ninja supports VLESS+relay (Scenario A)
MIHOMO_PORT="7890"        # Clash V-Ninja's listen port
XRAY_PORT="41792"
```

### Step 6: Run mac-setup.sh

```bash
bash mac-setup.sh
```

It asks 3 yes/no questions about Clash V-Ninja compatibility:
1. Does it have a raw YAML config editor?
2. Does it support `type: vless`?
3. Does it support `type: relay`?

- **All yes → Scenario A**: Prints config snippets to paste into Clash V-Ninja's YAML editor. No new software installed.
- **Any no → Scenario B**: Installs standalone mihomo (port 7891) alongside Clash V-Ninja, with auto-start via launchd, a PAC file for browser routing, and macOS system proxy configuration.

If unsure, answer `n` — Scenario B is the safer path.

#### What It Changes (Scenario B)

| File / Setting | Change |
|----------------|--------|
| `mihomo` | Installed via Homebrew |
| `~/.config/mihomo/config.yaml` | Proxy config with relay chain (chmod 600) |
| `~/Library/LaunchAgents/com.mihomo.proxy.plist` | launchd auto-start + auto-restart |
| `~/.config/mihomo/proxy.pac` | PAC file for browser proxy routing |
| macOS system proxy | PAC URL set on all active network services |
| `~/.ssh/id_ed25519` | Generated if missing |
| `~/.ssh/config` | `Host home` entry with ProxyCommand through tunnel |
| `~/.zshrc` | Proxy-wrapped `claude` and `openai` aliases |

#### What It Changes (Scenario A)

| File / Setting | Change |
|----------------|--------|
| `~/.ssh/id_ed25519` | Generated if missing |
| `~/.ssh/config` | `Host home` entry with ProxyCommand through tunnel |
| `~/.zshrc` | Proxy-wrapped `claude` and `openai` aliases |
| Clash V-Ninja config | You paste the printed snippets manually |

### Step 7: Verify

```bash
source ~/.zshrc

# Tunnel routing
curl --proxy http://127.0.0.1:7891 -sI https://claude.ai | head -3
# Expected: HTTP response (200 or 301)

# SSH through tunnel
ssh home
# Expected: connects to Ubuntu laptop

# Claude CLI
claude --version
# Expected: prints version without error

# Browser
# Open https://claude.ai and https://chatgpt.com — both should load
```

### Step 8: Clean Up

On the Ubuntu laptop, delete the credentials file:

```bash
sudo rm /root/mac-setup-values.txt
```

## Rerunning the Scripts

Both scripts are idempotent:

- **home-setup.sh**: Reuses existing credentials on rerun (extracts from config.json). Use `--rotate` to force new credentials.
- **mac-setup.sh**: Replaces existing SSH config stanza and shell aliases cleanly on rerun.

## Troubleshooting

| Problem | Check |
|---------|-------|
| `curl` through proxy hangs | Is Clash V-Ninja running? `lsof -iTCP:7890 -sTCP:LISTEN` |
| `ssh home` connection refused | Verify port forwarding: `nc -zv <HOME_IP> 22222` from phone |
| `ssh home` permission denied | Was the key installed? Check `~user/.ssh/authorized_keys` on Ubuntu |
| mihomo not listening (7891) | Check logs: `cat ~/.config/mihomo/mihomo.err` |
| Xray not reachable (41792) | Check router port forwarding, then `sudo ufw status` on Ubuntu |
| Browser doesn't use tunnel | Check system proxy: `networksetup -getautoproxyurl Wi-Fi` |
| DNS leaking | On Ubuntu: `sudo tcpdump -i any port 53 -n` while accessing AI sites from Mac — no queries for AI domains should appear |
| Some AI features broken | Set `log-level: debug` in mihomo config, check logs for blocked domains, uncomment Tier 2 rules |
| Laptop sleeps with lid closed | `grep HandleLidSwitch /etc/systemd/logind.conf` — all should be `ignore` |
| Xray crashes and doesn't restart | `journalctl -u xray -n 20` for error details; service has `Restart=always` |
| Health check failing | `journalctl -u xray-health -n 5` to see what's wrong |
