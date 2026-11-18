# Claude through your home internet

Run Claude Code through your home IP using an SSH tunnel. Your home computer can run Linux or macOS (including a Mac mini). Claude Code clients support Linux and macOS; the isolated browser currently requires a Linux client with a display. Mac browser launch refuses to run because proxy flags alone do not enforce all traffic.

This follows the working setup inspected on `arghome`: your existing Clash app carries SSH to home; SSH provides a local SOCKS proxy; a separate mihomo process converts it into the HTTP proxy Claude Code needs. No Xray, VLESS, subscription editing, or particular Clash brand is required.

```text
Claude Code + child processes / dedicated browser
    → home HTTP proxy (127.0.0.1:7891)
    → SSH SOCKS tunnel (127.0.0.1:10880)
    → your Clash app (127.0.0.1:7890; configurable)
    → SSH connection to home (public port 22222; configurable)
    → home internet → Claude, authentication, telemetry, MCP, downloads
```

Clash is the carrier to home. Its node's IP is not the Claude exit IP. If home disconnects, requests fail; there is no direct or other-node fallback. DNS for the home proxy also goes through home.

## Account safety and suspension notice

**This tool cannot prevent or guarantee protection from an account ban.** It controls network routing; it does not change your eligibility to use Claude, your account status, or Anthropic's enforcement decisions. A home or residential IP is not proof that an account is compliant.

To reduce avoidable account and connection problems:

- **Check your eligibility first.** Anthropic's current [Supported Regions Policy](https://www.anthropic.com/supported-countries) covers your physical location and your organization's incorporation, headquarters and ownership/control. Being physically in an unsupported region is not made eligible by routing through a home computer in a supported country. Do not use this tool to evade regional restrictions.
- **Keep your account private and accurate.** Use correct account and billing information. Do not share your login, session cookies, API keys or account access, or buy/rent shared accounts. These obligations are described in the [Consumer Terms](https://www.anthropic.com/legal/consumer-terms); organizational/API users should also check their applicable [Commercial Terms](https://www.anthropic.com/legal/commercial-terms).
- **Use official clients and permitted integrations.** Follow the [Usage Policy](https://www.anthropic.com/legal/aup) and your plan's limits. Do not bypass protective measures, rotate accounts to evade limits or suspensions, or expose your subscription as a shared/resold service. Use the API or another explicitly permitted interface for automation.
- **Verify the home route before use.** Run `home-tunnel doctor` and compare its exit IP with the home computer's actual public IP. Restart old Claude sessions and background processes after setup. API calls, authentication, telemetry, MCP and updates must use the same home tunnel; an environment variable alone is not evidence that every process is covered.
- **Stop when routing or isolation fails.** Do not switch to a normal browser, launch the raw Claude binary, add a direct fallback, or disable sandboxing to complete sign-in. macOS browser launch is currently blocked; Linux browsers require a working sandbox. Fix the unsupported path before continuing. Consistent routing prevents accidental bypasses; it is not an account-safety guarantee.
- **Handle warnings through official support.** If access is restricted, stop repeated login attempts and use Anthropic's [account-ban appeal instructions](https://support.claude.com/en/articles/8241253-how-to-appeal-an-account-ban). Do not try to evade a suspension with another account or a different IP. Never publish credentials or authentication logs when asking for help.

There is no documented “safe” number of IP changes, guaranteed safe proxy provider, or ban-proof home-IP setup. This project makes no such claims. Policies can change: check the official links above before deploying. The policy links were reviewed on **2026-11-18**.

## Before you start

You need two computers, a client SSH key, and access to your home router settings. Keep the home computer powered on and connected to the internet.

| Computer | What to install |
| --- | --- |
| Client Mac | Python 3, OpenSSH/netcat/curl (normally provided by macOS), mihomo (`brew install mihomo`), Chrome or Chromium, your usual Clash app |
| Client Linux | Python 3, OpenSSH client, curl, **OpenBSD** netcat, bubblewrap, mihomo, Chrome or Chromium, your usual Clash app |
| Home Linux | Python 3 and OpenSSH server; Ubuntu/Debian can install the server using the helper below |
| Home Mac mini | Python 3; turn on **System Settings → General → Sharing → Remote Login** for your user |

Ubuntu/Debian client prerequisites:

```bash
sudo apt update
sudo apt install python3 openssh-client curl netcat-openbsd bubblewrap
```

Install [mihomo](https://github.com/MetaCubeX/mihomo/releases) for your operating system and CPU. If your Clash app already includes a mihomo-compatible executable, you can give its full path to the wizard; the tool starts it with a separate private configuration. Homebrew and Python installers: [brew.sh](https://brew.sh), [python.org](https://www.python.org/downloads/).

On Linux, unprivileged user/network namespaces must be allowed, including the browser’s own nested sandbox. Setup stops if bubblewrap cannot create one. Snap-packaged Chromium may not work inside this namespace; use a regular Chrome/Chromium package with its distribution-provided AppArmor/user-namespace permissions. If Chrome reports “No usable sandbox”, resolve its supported installation/policy; do not add `--no-sandbox`. On macOS, setup requires the built-in `sandbox-exec`; Apple marks it deprecated, so future macOS versions may require a different isolation backend. The tool stops if Claude network isolation cannot start.

## 1. Create your client key

Run on the computer where you use Claude:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/home_tunnel_ed25519 -C home-tunnel
cat ~/.ssh/home_tunnel_ed25519.pub
```

Keep the private file `home_tunnel_ed25519` on the client. Copy only the one-line **`.pub`** file to the home computer (USB or an existing secure connection is fine). Do not overwrite an existing key. If you choose a passphrase, load the key with `ssh-add ~/.ssh/home_tunnel_ed25519` before setup. Automatic restart requires an available SSH agent with that key loaded; an unattended dedicated key can instead have an empty passphrase.

## 2. Prepare the home computer

Copy this repo to the home computer. Run the helper there as the home login user:

```bash
bash home-setup.sh --ssh-pubkey /path/on/home/computer/home_tunnel_ed25519.pub
```

This adds the client public key, prints the home public IP and host-key fingerprints, and explains the router mapping. It preserves existing SSH authentication, listener and firewall settings. You can also run `bash home-setup.sh` and paste the client public key when asked.

To install/enable the SSH server and keep a plugged-in home machine awake:

```bash
sudo bash home-setup.sh --user alex \
  --ssh-pubkey /path/on/home/computer/home_tunnel_ed25519.pub \
  --enable-ssh --keep-awake
```

Replace `alex` with the home user's login name. On a Mac, enabling Remote Login from Terminal may require Full Disk Access; use the Sharing settings UI if macOS refuses. On a Linux laptop, also disable automatic suspend in the desktop Power settings; lid settings take effect after reboot. The Linux keep-awake option masks sleep/suspend targets. On a Mac, it disables computer sleep on AC power and saves the previous power settings in `~/home-tunnel-power-before.txt`.

The script does not change the SSH port or automatically disable password login. Keep an existing working login while testing the new key. OpenSSH must permit local TCP forwarding; check `AllowTcpForwarding` and any restrictions on the installed key if forwarding is denied.

## 3. Set the home router

Open the router's app or administration page. Find **Port forwarding**, **Virtual server**, or **NAT forwarding** and add:

| Router field | Value |
| --- | --- |
| Protocol | TCP |
| External/public port | `22222` |
| Internal/device IP | The home computer's LAN address (for example `192.168.1.50`) |
| Internal/device port | `22`, or the port where your existing SSH server listens |

Set a DHCP reservation for that computer so its LAN address stays the same. Allow the **internal SSH port** in the home computer's existing firewall. For an already enabled Ubuntu UFW firewall and an SSH server on 22, this is `sudo ufw allow 22/tcp`. Do not enable/reset a firewall blindly over a remote connection.

The external and internal ports can differ. On the inspected setup the home SSH endpoint is reachable on external `22222`; new installations can simply map `22222 → 22` without editing sshd.

Compare the router's **WAN/internet IPv4** with the public IPv4 printed by home setup. If they differ, investigate double NAT. If your ISP uses CGNAT (often a WAN address in `100.64.0.0/10` or a private range), ask it for a public IP; port forwarding alone is insufficient. A hostname from your router's DDNS feature can follow a changing public IP. No relay alternative is silently installed.

Find the LAN IP under the home computer's Network settings. Reserve that address in the router. Keep the printed public IP and SSH fingerprints for the next step. Test from a different network, such as your client on a phone hotspot; testing inside home Wi-Fi may fail if the router lacks NAT loopback.

## 4. Run the client wizard

Start your usual Clash app and select a working node. In its settings, find **HTTP port**, **Mixed port**, or **SOCKS port**. Typical values are `7890`, `7897`, or `8080`; the number in your app is what matters. A mixed port uses the `connect` option. A SOCKS5-only port uses `5`.

Run **without sudo**:

```bash
bash setup.sh client
```

The wizard asks for the home address, home login name, external SSH port, Clash port, and SSH key path. It detects common Clash ports and keeps the internal ports at sensible defaults; use flags if you need to change them. Press Enter to accept suggested values. You never need to edit source code or Clash subscription files.

On first connection, compare the SSH fingerprint with the one printed on the home computer. Accept only if it matches. The wizard then checks key login, forwarding and home egress; validates the proxy and isolation configuration; installs login services; adds command launchers to your shell; and merges proxy/launcher settings into `~/.claude/settings.json`. Changed files receive timestamped `.bak-*` backups. Host trust is stored separately from your existing SSH configuration.

Open a **new terminal**, restart existing Claude sessions, then run:

```bash
home-tunnel doctor
claude
```

For current Claude Code versions, stop any previously running background supervisor with `claude daemon stop --any` before starting background sessions. The self-spawn launcher uses `CLAUDE_CODE_PROCESS_WRAPPER`, supported since Claude Code 2.1.208. Older versions should be updated before using detached/background sessions. See [Anthropic's launcher contract](https://code.claude.com/docs/en/corporate-launcher).

For sign-in, run this in another terminal and paste the URL printed by Claude:

```bash
home-browser 'https://claude.ai/...'
```

On Linux, use this dedicated browser for all Claude web use. It has a separate profile, one fixed proxy with no direct fallback, disabled background networking and QUIC, restricted WebRTC, and OS network isolation. On macOS, `home-browser` refuses to open: Chrome cannot initialize its own sandbox under the inherited OS network sandbox. Use an isolated Linux VM/client with a display for browser sign-in. A home Mac mini works normally as the SSH server; this limitation concerns the browser on the client. Automatic browser opening may be blocked; the manual command is deliberate. On Linux the browser cannot reach a callback listener in Claude's separate namespace; use Claude's displayed code/paste-URL sign-in flow. Never complete that flow in your ordinary browser.

### What is covered

The installed `claude` launcher isolates Claude Code and its descendants. Proxy-aware API, auth, telemetry, updater and MCP requests go through home. A child that ignores the proxy cannot connect directly; it fails instead. `home-run COMMAND ...` applies the same rules to another command. On Linux, the dedicated `home-browser` isolates Chrome/Chromium and routes it through the same home HTTP proxy, including sign-in. On macOS browser launch fails closed until an enforceable backend is available.

The proxy sends **every destination** through home, so there is no incomplete domain allowlist to maintain. Inherited proxy variables are overwritten in uppercase and lowercase; proxy exceptions are limited to loopback for local callbacks.

These are application launchers, not a system VPN. Existing sessions, an absolute Claude binary launched outside the wrapper, IDE extensions, Claude Desktop, a normal browser, Docker containers, already-running MCP daemons, and third-party services that delegate work outside the process tree are not automatically isolated. Launch the relevant command through `home-run` when compatible. GUI/deep-link launchers and terminal multiplexers can start external processes; avoid those paths for Claude. New deep-link registration is disabled in Claude settings; existing handlers are not removed. This does not attempt to contain intentionally hostile programs with access to your user account, privileged processes, or arbitrary desktop IPC.

Linux network namespaces block all external network interfaces and expose only the home HTTP proxy through a private Unix socket. Unix sockets/files are still available, so do not connect Claude to an unrelated local proxy/daemon that uses a different exit. macOS applies an inherited outbound-network sandbox to Claude and its children, allowing only the home HTTP proxy port; launching the normal browser via LaunchServices is blocked. The tool does not launch an unisolated Mac browser as a workaround. Existing OS services remain outside that sandbox.

[Claude Code requires an HTTP proxy rather than a SOCKS proxy](https://code.claude.com/docs/en/network-config), which is why the small standalone mihomo process is included. TLS remains end-to-end; no custom CA or TLS interception is installed.

### Flags and preview

For a repeatable setup after enrolling the home fingerprint interactively once, use flags:

```bash
bash setup.sh client --noninteractive \
  --home-host home.example.net --home-user alex --home-port 22222 \
  --identity ~/.ssh/home_tunnel_ed25519 \
  --upstream-port 7897 --upstream-type connect \
  --mihomo /opt/homebrew/bin/mihomo
```

For a SOCKS5-only Clash listener, use `--upstream-type 5` and its SOCKS port. Only loopback upstream ports are accepted. Authenticated upstream proxies are not supported; use a local unauthenticated loopback listener.

Review generated files without connecting, registering services, or editing shell/Claude settings:

```bash
bash setup.sh client --generate-only --noninteractive \
  --home-host home.example.net --home-user alex \
  --mihomo /path/to/mihomo --output /tmp/home-tunnel-preview
```

`--target-os Linux` or `--target-os Darwin` previews either service format. Use `bash setup.sh client --help` for all flags. `bash mac-setup.sh` remains an entry point for older instructions and now uses the same wizard. Setup needs all repo files beside it; copying just the `.sh` entry point is insufficient.

## Check, stop, or update

```bash
home-tunnel doctor       # listeners, home IP equality, direct-network denial, isolated home request
home-tunnel status      # OS service status
home-tunnel stop        # stops this tool's services; wrapped Claude loses network access
home-tunnel start
home-tunnel restart
home-browser            # dedicated Claude browser
home-run curl https://api.ipify.org
```

Doctor compares the SOCKS and HTTP egress IPs. Compare the result with the IP on the actual home computer. Supplying `--expected-ip YOUR_HOME_IPV4` also checks against that value; update it after an independently verified home IP change. All IP checks use the explicit home route; none tries direct client internet as a fallback.

To change the address, ports or key: `home-tunnel stop`, rerun `bash setup.sh client`, open a new terminal, then run doctor. The wizard remembers previous answers. It refuses occupied ports and never stops unrelated services. Default state is `~/.config/home-tunnel`, separate from your existing mihomo and Clash directories.

macOS launch agents start when you log in; Linux user services normally start at login. If a Linux client must maintain the tunnel while logged out, enable lingering explicitly: `sudo loginctl enable-linger "$USER"`. If the key needs an SSH agent, make sure it is available to the user service as well. For Linux passphrased keys, an agent started only inside a terminal is generally insufficient for user services; configure a stable user agent socket or use an unattended dedicated key. User services inherit the systemd user-manager environment; after loading a key, `systemctl --user import-environment SSH_AUTH_SOCK` makes the current socket available until it changes.

| Problem | What to do |
| --- | --- |
| Clash port closed | Start the app; confirm the actual HTTP/mixed or SOCKS port in its settings |
| SSH refused/timed out | Check the home public IP/DDNS, external-to-internal router mapping, firewall, sleep and CGNAT |
| Permission denied | Confirm the `.pub` key is installed for the same home user and the client has the corresponding private key loaded |
| Host key changed | Independently compare home fingerprints; do not delete known-host entries just to dismiss the warning |
| Local port already in use | Stop this tool before rerunning or choose free `--http-port`/`--socks-port` values; do not overwrite an old proxy |
| Proxy or tunnel fails after login | Read `~/.config/home-tunnel/logs/*.err` on Mac; Linux: `journalctl --user -u home-tunnel-ssh -u home-tunnel-proxy -u home-tunnel-relay -n 60` |
| Direct networking fails in a tool | This is expected for tools ignoring proxies. Configure the tool to use the HTTP proxy; no bypass is added |
| Browser says No usable sandbox | Use a supported Chrome/Chromium package and its sandbox policy; never add `--no-sandbox` |
| Browser fails to open automatically | Run `home-browser 'SIGN_IN_URL'` in another terminal and use Claude's manual code flow |
| Linux isolation denied | Check bubblewrap installation and your distribution's unprivileged user-namespace policy; do not bypass the isolation requirement |
| Home IP changed | Verify the new IP on the home computer, update DDNS/address and any `--expected-ip`, rerun setup |

For removal, first stop services. Linux: `systemctl --user disable home-tunnel-{ssh,proxy,relay}.service`. Remove only this tool's `local.home-tunnel-*.plist` (Mac) or `home-tunnel-*.service` (Linux) service files. Restore backed-up shell and Claude settings, or remove the `home-tunnel` shell block and the proxy/launcher/deep-link settings added above while preserving later edits. Remove `~/.config/home-tunnel` last. The home helper only adds a public key unless optional server/power flags are used; remove that key line to revoke access. Linux sleep masks can be undone with `sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target` and removal of `/etc/systemd/logind.conf.d/90-home-tunnel.conf`; restore Mac power settings from the saved values.

## Development

```bash
python3 -m unittest discover -s tests -v
shellcheck setup.sh mac-setup.sh home-setup.sh
```

Tests use temporary files and disposable local listeners. They do not install services or change your production network. Live checks should use spare ports and stop only the processes created for the check. No personal addresses, usernames or private keys belong in this repo.
