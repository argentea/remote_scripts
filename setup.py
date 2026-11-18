#!/usr/bin/env python3
"""Guided SSH home-egress setup for macOS and Linux. Python standard library only."""
import argparse
import datetime
import getpass
import ipaddress
import json
import os
from pathlib import Path
import platform
import plistlib
import pwd
import re
import shlex
import shutil
import subprocess
import sys
import time

import tunnel

SOURCE = Path(__file__).resolve().parent
DEFAULT_STATE = Path.home() / '.config/home-tunnel'


def write(path, content, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_bytes() != (content if isinstance(content, bytes) else content.encode()):
        stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
        backup = path.with_name(path.name + '.bak-' + stamp)
        shutil.copy2(path, backup)
    import tempfile
    # Create private before writing, including in a shared preview directory.
    descriptor, filename = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    temporary = Path(filename)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, 'wb') as stream:
            stream.write(content if isinstance(content, bytes) else content.encode())
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def ask(label, default='', supplied=None, required=False, noninteractive=False):
    if supplied is not None:
        value = str(supplied)
    elif noninteractive:
        value = str(default)
    else:
        value = input(f'{label}' + (f' [{default}]' if default != '' else '') + ': ').strip() or str(default)
    if required and not value:
        tunnel.fail(f'{label} is required. See --help for the matching flag.')
    return value


def port(value):
    try:
        result = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError('Use a port number, for example 7890.') from None
    if not 1024 <= result <= 65535:
        raise argparse.ArgumentTypeError('Use a local port from 1024 to 65535.')
    return result


def ssh_port(value):
    try:
        result = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError('Use a port number, for example 22222.') from None
    if not 1 <= result <= 65535:
        raise argparse.ArgumentTypeError('Use a port from 1 to 65535.')
    return result


def valid_host(value):
    # No shell/control/config expansion in OpenSSH's ProxyCommand destination.
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.:-]*', value):
        tunnel.fail('Home address must be a public IP or DNS name, with no spaces, scheme or port.')
    return value


def valid_user(value):
    if not re.fullmatch(r'[a-zA-Z_][a-zA-Z0-9_.-]*', value):
        tunnel.fail('Enter the home login name only, such as alex (no spaces or @address).')
    if value == 'root':
        tunnel.fail('Use a normal home login account, not root.')
    return value


def browser_path():
    candidates = [
        '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
        '/Applications/Chromium.app/Contents/MacOS/Chromium',
        str(Path.home() / 'Applications/Google Chrome.app/Contents/MacOS/Google Chrome'),
    ]
    for name in ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']:
        found = shutil.which(name)
        if found:
            candidates.append(found)
    return next((p for p in candidates if Path(p).is_file()), '')


def find_mihomo():
    # The application need only expose a local HTTP CONNECT or SOCKS5 port.
    for name in ['mihomo', 'ninja-mihomo', 'clash-meta']:
        found = shutil.which(name)
        if found:
            return str(Path(found).absolute())
    return ''


def detect_upstream():
    # Probe only common local listeners, never a public endpoint or a fallback route.
    for number in [7890, 7897, 8080, 1080]:
        if tunnel.port_open(number):
            return number
    return 7890


def launcher(python, runtime, action):
    return '#!/bin/sh\nexec ' + shlex.join([python, str(runtime), action]) + ' "$@"\n'


def services(c, directory):
    actions = [('ssh', 'home-tunnel-ssh'), ('proxy', 'home-tunnel-proxy')]
    if c['platform'] == 'Linux':
        actions.append(('relay', 'home-tunnel-relay'))
    result = {}
    for action, name in actions:
        command = [c['python'], str(directory / 'tunnel.py'), action]
        if c['platform'] == 'Darwin':
            label = 'local.' + name
            data = {'Label': label, 'ProgramArguments': command, 'RunAtLoad': True,
                    'KeepAlive': True, 'ThrottleInterval': 10,
                    'StandardOutPath': str(directory / 'logs' / (action + '.log')),
                    'StandardErrorPath': str(directory / 'logs' / (action + '.err'))}
            result[label + '.plist'] = plistlib.dumps(data)
        else:
            # systemd expands percent specifiers even inside quotes.
            escaped = ['"' + p.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'
                       for p in command]
            result[name + '.service'] = (
                '[Unit]\nDescription=Home SSH tunnel: ' + action + '\n'
                '[Service]\nType=simple\nExecStart=' + ' '.join(escaped) + '\n'
                'Restart=always\nRestartSec=10\nUMask=0077\n'
                '[Install]\nWantedBy=default.target\n')
    return result


def merge_settings(path, c, directory):
    value = json.loads(path.read_text()) if path.exists() else {}
    if not isinstance(value, dict) or not isinstance(value.get('env', {}), dict):
        tunnel.fail(f'{path} must contain a JSON object with an object named env.')
    env = tunnel.proxy_env(c)
    keys = ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy',
            'NO_PROXY', 'no_proxy', 'BROWSER']
    value.setdefault('env', {}).update({k: env[k] for k in keys})
    # Quoted argv JSON handles installation paths containing spaces.
    value['env']['BROWSER'] = str(directory / 'bin/home-browser')
    value['env']['CLAUDE_CODE_PROCESS_WRAPPER'] = json.dumps([str(directory / 'bin/home-run')])
    value['disableDeepLinkRegistration'] = 'disable'
    return json.dumps(value, indent=2) + '\n'


def shell_block(directory):
    return ('# >>> home-tunnel >>>\n'
            'unalias claude 2>/dev/null || true\n'
            # Remove older shell functions so they cannot shadow the PATH wrapper.
            'unset -f claude 2>/dev/null || true\n'
            'export PATH=' + shlex.quote(str(directory / 'bin')) + ':"$PATH"\n'
            '# <<< home-tunnel <<<\n')


def merge_shell(text, directory):
    # Migrate the repo's former alias blocks too; a lingering alias wins over PATH.
    patterns = [r'(?m)^# >>> home-tunnel >>>\n.*?^# <<< home-tunnel <<<\n?',
                r'(?m)^# >>> AI CLI proxy aliases[^\n]*\n.*?^# <<< AI CLI proxy aliases <<<\n?']
    for pattern in patterns:
        text = re.sub(pattern, '', text, flags=re.S)
    return text.rstrip() + '\n\n' + shell_block(directory)


def render(c, directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    (directory / 'logs').mkdir(exist_ok=True)
    write(directory / 'tunnel.py', (SOURCE / 'tunnel.py').read_text(), 0o700)
    write(directory / 'config.json', json.dumps(c, indent=2) + '\n')
    write(directory / 'mihomo/config.yaml', tunnel.mihomo_yaml(c))
    write(directory / 'network.sb', tunnel.sandbox_profile(c))
    for name, action in [('claude', 'claude'), ('home-run', 'run'),
                         ('home-browser', 'browser')]:
        write(directory / 'bin' / name, launcher(c['python'], directory / 'tunnel.py', action), 0o700)
    write(directory / 'bin/home-tunnel', '#!/bin/sh\nexec ' + shlex.join(
        [c['python'], str(directory / 'tunnel.py')]) + ' "$@"\n', 0o700)
    for name, content in services(c, directory).items():
        write(directory / 'services' / name, content)


def preflight(c, noninteractive=False):
    for name in ['ssh', 'nc', 'curl', 'mihomo']:
        if not Path(c[name]).is_file():
            tunnel.fail(f'{name} executable not found: {c[name]}')
    help_nc = subprocess.run([c['nc'], '-h'], capture_output=True, text=True)
    if '-X' not in help_nc.stdout + help_nc.stderr:
        tunnel.fail('This nc does not support proxying (-X). Ubuntu: sudo apt install netcat-openbsd.')
    if c['platform'] == 'Linux' and not c.get('bwrap'):
        tunnel.fail('bubblewrap is required. Ubuntu/Debian: sudo apt install bubblewrap netcat-openbsd')
    if c['platform'] == 'Darwin' and not Path('/usr/bin/sandbox-exec').exists():
        tunnel.fail('This macOS has no sandbox-exec. Network isolation is required; setup stopped.')
    if not tunnel.port_open(c['upstream_port']):
        tunnel.fail(f'Clash port {c["upstream_port"]} is closed. Start your Clash app and check its HTTP/mixed or SOCKS port.')
    identity = Path(c['identity'])
    if not identity.is_file():
        tunnel.fail(f'SSH key not found: {identity}. See README: create a key and install its .pub file at home.')
    # Detect conflicts before making a connection or altering any running service.
    for key in ['socks_port', 'http_port']:
        if tunnel.port_open(c[key]):
            tunnel.fail(f'Port {c[key]} is in use. Stop this tool with home-tunnel stop before rerunning, or choose another port. Existing services were left running.')
    print('\nChecking SSH through your Clash app. On first connection, compare the fingerprint with the home computer.')
    args = tunnel.ssh_args(c)
    lookup = c['home_host'] if c['home_port'] == 22 else f'[{c["home_host"]}]:{c["home_port"]}'
    known = subprocess.run(['ssh-keygen', '-F', lookup, '-f', c['known_hosts']], capture_output=True)
    if known.returncode:
        if noninteractive:
            tunnel.fail('Home fingerprint has not been enrolled. Run the interactive wizard once to compare and accept it.')
        # Host enrollment only; no password or remote shell needed. Authentication
        # intentionally fails after the normal OpenSSH fingerprint confirmation.
        enroll = list(args)
        destination = enroll.pop()
        enroll.remove('-NT')
        pos = enroll.index('-D')
        del enroll[pos:pos + 2]
        enroll[enroll.index('BatchMode=yes')] = 'BatchMode=no'
        enroll[enroll.index('StrictHostKeyChecking=yes')] = 'StrictHostKeyChecking=ask'
        enroll += ['-o', 'PreferredAuthentications=none', destination, 'true']
        subprocess.run(enroll)
        known = subprocess.run(['ssh-keygen', '-F', lookup, '-f', c['known_hosts']], capture_output=True)
        if known.returncode:
            tunnel.fail('Home fingerprint was not accepted. No services were installed.')
    process = subprocess.Popen(args)
    try:
        deadline = time.monotonic() + 22
        while process.poll() is None and time.monotonic() < deadline:
            if tunnel.port_open(c['socks_port']):
                actual = tunnel.egress_ip(c, socks=True)
                if c.get('expected_ip') and actual != c['expected_ip']:
                    tunnel.fail(f'The SSH exit IP is {actual}, expected {c["expected_ip"]}. Verify at home before continuing.')
                print('Verified SSH forwarding. Home egress IP: ' + actual)
                break
            time.sleep(0.2)
        else:
            tunnel.fail('SSH check failed. Verify key, router, fingerprint, forwarding permissions and Clash. No services were installed.')
    finally:
        process.terminate()
        process.wait(timeout=5)


def install_services(c, directory):
    if c['platform'] == 'Darwin':
        destination = Path.home() / 'Library/LaunchAgents'
    else:
        destination = Path.home() / '.config/systemd/user'
    names = []
    for name, content in services(c, directory).items():
        write(destination / name, content)
        names.append(name)
    if c['platform'] == 'Linux':
        subprocess.run(['systemctl', '--user', 'daemon-reload'], check=True)
        subprocess.run(['systemctl', '--user', 'enable', '--now', *names], check=True)
    else:
        for name in names:
            label = name[:-len('.plist')]
            subprocess.run(['launchctl', 'bootout', f'gui/{os.getuid()}/{label}'], capture_output=True)
            subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(destination / name)], check=True)


def client(options):
    if os.geteuid() == 0:
        tunnel.fail('Run client setup as your normal user, without sudo.')
    system = options.target_os or platform.system()
    if system not in ['Linux', 'Darwin']:
        tunnel.fail('Client setup supports macOS and Linux.')
    directory = Path(options.output).expanduser().absolute()
    old_file = directory / 'config.json'
    old = json.loads(old_file.read_text()) if old_file.exists() else {}
    def field(label, key, default='', required=False):
        return ask(label, old.get(key, default), getattr(options, key, None), required, options.noninteractive)
    print('Your computer → local home proxy → SSH tunnel → home internet\n'
          'Your existing Clash app carries only the SSH connection. No Clash profile editing is needed.\n')
    home_host = valid_host(field('Home public address or DDNS name', 'home_host', required=True))
    home_user = valid_user(field('Login name on the home computer', 'home_user', required=True))
    home_port = ssh_port(field('Router external SSH port', 'home_port', 22222))
    upstream_type = field('Clash port type: connect (HTTP/mixed) or 5 (SOCKS5)', 'upstream_type', 'connect')
    if upstream_type not in ['connect', '5']:
        tunnel.fail('Choose connect for an HTTP/mixed port, or 5 for SOCKS5.')
    upstream_port = port(field('Clash local port (find it in your app Settings → Ports)', 'upstream_port', detect_upstream()))
    identity = str(Path(field('Private SSH key on this computer', 'identity',
                              str(Path.home() / '.ssh/home_tunnel_ed25519'))).expanduser().absolute())
    # Internal ports rarely need changing; keep them out of the novice wizard.
    socks_port = port(options.socks_port or old.get('socks_port', 10880))
    http_port = port(options.http_port or old.get('http_port', 7891))
    if len({socks_port, http_port, upstream_port}) != 3:
        tunnel.fail('The Clash, SSH tunnel and home HTTP ports must be different.')
    expected_ip = field('Home public IPv4 shown by home setup (Enter to skip)', 'expected_ip')
    if expected_ip:
        expected_ip = str(ipaddress.IPv4Address(expected_ip))
    mihomo = field('Mihomo executable (Mac: brew install mihomo)', 'mihomo', find_mihomo(), required=True)
    mihomo = str(Path(mihomo).expanduser().absolute())
    browser = field('Chrome/Chromium executable (Linux browser only; Enter to defer)', 'browser', browser_path() if system == 'Linux' else '')
    if browser:
        browser = str(Path(browser).expanduser().absolute())
    c = dict(platform=system, home_host=home_host, home_user=home_user, home_port=home_port,
             upstream_type=upstream_type, upstream_port=upstream_port, identity=identity,
             socks_port=socks_port, http_port=http_port, expected_ip=expected_ip,
             mihomo=mihomo, browser=browser, python=str(Path(sys.executable).absolute()),
             ssh=tunnel.executable('ssh'), nc=tunnel.executable('nc'), curl=tunnel.executable('curl'),
             known_hosts=str(directory / 'known_hosts'), bwrap=shutil.which('bwrap') or '')
    if options.generate_only:
        render(c, directory)
        write(directory / 'claude-settings.preview.json', merge_settings(Path('/nonexistent/home-tunnel-settings'), c, directory))
        write(directory / 'shell.preview.sh', shell_block(directory))
        print(f'Generated files in {directory}. No services, keys, shells or Claude settings were changed.')
        return
    legacy_bin = Path.home() / '.config/ai-ssh-proxy/bin'
    if legacy_bin.resolve() == (directory / 'bin').resolve():
        tunnel.fail('Use the default ~/.config/home-tunnel directory to migrate from the old launcher.')
    # Validate existing JSON before any system/profile writes.
    settings_path = Path.home() / '.claude/settings.json'
    settings = merge_settings(settings_path, c, directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory.chmod(0o700)
    Path(c['known_hosts']).touch(mode=0o600, exist_ok=True)
    preflight(c, options.noninteractive)
    render(c, directory)
    subprocess.run([mihomo, '-t', '-d', str(directory / 'mihomo')], check=True)
    # Ensure the requested isolation mechanism actually works before installing.
    if system == 'Darwin':
        command = ['/usr/bin/sandbox-exec', '-f', str(directory / 'network.sb'), c['python'], '-c', 'pass']
    else:
        command = [c['bwrap'], '--unshare-net', '--bind', '/', '/', '--', c['python'], '-c', 'pass']
    subprocess.run(command, check=True)
    write(settings_path, settings)
    for filename in ['.zshrc', '.bashrc', '.profile']:
        path = Path.home() / filename
        write(path, merge_shell(path.read_text() if path.exists() else '', directory))
    install_services(c, directory)
    print('\nInstalled. Open a NEW terminal; restart existing Claude sessions and background services.\n'
          'Run: home-tunnel doctor\nRun Claude: claude\nOpen sign-in/browser on Linux: home-browser\n'
          'Linux services start at login. See README for running them while logged out.\n'
          'Your previous file versions were saved beside each changed file as .bak-* files.')
    if system == 'Darwin':
        print('Mac browser launch is blocked: use a supported isolated Linux client/VM for sign-in. See README.')


def public_key(value):
    path = Path(value).expanduser()
    text = path.read_text().strip() if not value.startswith(('ssh-', 'ecdsa-', 'sk-')) else value.strip()
    if '\n' in text or not re.fullmatch(r'(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp\d+|sk-[^ ]+) [A-Za-z0-9+/]+=*(?: [^\r\n]*)?', text):
        tunnel.fail('Use one OpenSSH public key (.pub), never a private key.')
    probe = subprocess.run(['ssh-keygen', '-lf', '/dev/stdin'], input=text, text=True, capture_output=True)
    if probe.returncode:
        tunnel.fail('ssh-keygen could not validate this public key.')
    return text


def home(options):
    system = platform.system()
    if system not in ['Darwin', 'Linux']:
        tunnel.fail('Run home setup on the home Linux computer or Mac mini.')
    user = options.user or os.environ.get('SUDO_USER') or getpass.getuser()
    user = valid_user(user)
    account = pwd.getpwnam(user)
    key_value = ask('Path to the CLIENT public key (.pub), or paste the public key', supplied=options.ssh_pubkey,
                    required=True, noninteractive=options.noninteractive)
    key = public_key(key_value)
    home_dir = Path(account.pw_dir)
    ssh_dir = home_dir / '.ssh'
    ssh_dir.mkdir(mode=0o700, exist_ok=True)
    ssh_dir.chmod(0o700)
    authorized = ssh_dir / 'authorized_keys'
    existing = authorized.read_text() if authorized.exists() else ''
    key_parts = key.split()[:2]
    if not any(line.split()[:2] == key_parts for line in existing.splitlines()):
        write(authorized, existing.rstrip() + '\n' + key + '\n')
    authorized.chmod(0o600)
    if os.geteuid() == 0:
        for path in [ssh_dir, authorized]:
            os.chown(path, account.pw_uid, account.pw_gid)
    if options.enable_ssh:
        if os.geteuid() != 0:
            tunnel.fail('--enable-ssh requires sudo. The public key was installed; rerun with sudo and --user.')
        if system == 'Darwin':
            subprocess.run(['/usr/sbin/systemsetup', '-setremotelogin', 'on'], check=True)
        else:
            if not shutil.which('sshd') and not Path('/usr/sbin/sshd').exists():
                if not shutil.which('apt-get'):
                    tunnel.fail('Install openssh-server using your distribution package manager first.')
                subprocess.run(['apt-get', 'update'], check=True)
                subprocess.run(['apt-get', 'install', '-y', 'openssh-server'], check=True)
            enabled = subprocess.run(['systemctl', 'enable', '--now', 'ssh'], capture_output=True)
            if enabled.returncode:
                subprocess.run(['systemctl', 'enable', '--now', 'sshd'], check=True)
    if options.keep_awake:
        if os.geteuid() != 0:
            tunnel.fail('--keep-awake requires sudo. Rerun with sudo and --user.')
        if system == 'Darwin':
            saved = subprocess.check_output(['pmset', '-g', 'custom'], text=True)
            write(home_dir / 'home-tunnel-power-before.txt', saved)
            subprocess.run(['pmset', '-c', 'sleep', '0'], check=True)
        else:
            write('/etc/systemd/logind.conf.d/90-home-tunnel.conf',
                  '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore\n', 0o644)
            subprocess.run(['systemctl', 'mask', 'sleep.target', 'suspend.target',
                            'hibernate.target', 'hybrid-sleep.target'], check=True)
            print('Lid setting takes effect after reboot. Also disable desktop automatic suspend in Power settings.')
    print(f'\nPublic key installed for {user}. SSH listener/authentication/firewall settings were preserved.')
    print('Home host-key fingerprints (compare with the CLIENT SSH prompt):')
    for file in sorted(Path('/etc/ssh').glob('ssh_host_*_key.pub')):
        subprocess.run(['ssh-keygen', '-lf', str(file)], check=True)
    if shutil.which('curl'):
        result = subprocess.run(['curl', '--proxy', '', '--noproxy', '*', '-4fsS', '--max-time', '10',
                                 'https://api.ipify.org'], capture_output=True, text=True)
        try:
            print('Home public IPv4: ' + str(ipaddress.IPv4Address(result.stdout.strip())))
        except ValueError:
            print('Public IP lookup unavailable; check it in the router internet/WAN page.')
    print(f'Client login name: {user}\nRouter mapping: external TCP {options.external_port} → this computer LAN IP :{options.local_port}\n'
          'Reserve this computer LAN IP in the router DHCP settings. Compare router WAN IP with home public IP.\n'
          'If behind CGNAT, ask the ISP for a public IP; port forwarding alone cannot work.\n'
          'Allow the LOCAL SSH port in your existing firewall, and enable TCP forwarding in sshd if disabled.\n'
          'Test from outside your home Wi-Fi before changing any login/security settings.\n'
          'On Mac: enable System Settings → General → Sharing → Remote Login for this user; keep the Mac plugged in.\n'
          'Do not disable passwords or close your old SSH port until a new key-based login succeeds.')


def parser():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    c = sub.add_parser('client', help='Set up the computer where you run Claude')
    for flag, help_text in [('home-host', 'Home public IP or DDNS name'), ('home-user', 'Home login username'),
                            ('identity', 'Private SSH key path'), ('mihomo', 'Path to mihomo binary'),
                            ('browser', 'Chrome/Chromium executable path'), ('expected-ip', 'Verified home public IPv4')]:
        c.add_argument('--' + flag, help=help_text)
    c.add_argument('--home-port', type=ssh_port)
    c.add_argument('--upstream-port', type=port, help='Local Clash HTTP/mixed or SOCKS port')
    c.add_argument('--upstream-type', choices=['connect', '5'])
    c.add_argument('--http-port', type=port)
    c.add_argument('--socks-port', type=port)
    c.add_argument('--output', default=str(DEFAULT_STATE), help='Private installation directory')
    c.add_argument('--noninteractive', action='store_true', help='Use flags/defaults without wizard prompts')
    c.add_argument('--generate-only', action='store_true', help='Write reviewable files only; do not install or connect')
    c.add_argument('--target-os', choices=['Darwin', 'Linux'], help='Preview another OS (requires --generate-only)')
    h = sub.add_parser('home', help='Prepare your home Linux computer or Mac mini')
    h.add_argument('--user', help='Home account to receive the key; required when logged in as root')
    h.add_argument('--ssh-pubkey', help='Client public key text or .pub path ON THIS computer')
    h.add_argument('--local-port', type=ssh_port, default=22, help='Existing sshd listener; script does not change it')
    h.add_argument('--external-port', type=ssh_port, default=22222, help='Router public SSH port for printed instructions')
    h.add_argument('--enable-ssh', action='store_true', help='Enable/install OpenSSH server (requires sudo)')
    h.add_argument('--keep-awake', action='store_true', help='Disable sleep on AC / Linux suspend (requires sudo)')
    h.add_argument('--noninteractive', action='store_true')
    return p


def main():
    p = parser()
    options = p.parse_args()
    if options.command == 'client':
        if options.target_os and not options.generate_only:
            p.error('--target-os requires --generate-only')
        client(options)
    else:
        home(options)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f'Setup: {error}', file=sys.stderr)
        sys.exit(1)
    except (EOFError, KeyboardInterrupt):
        print('\nSetup cancelled. Rerun when ready.', file=sys.stderr)
        sys.exit(1)
