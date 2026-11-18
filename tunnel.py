#!/usr/bin/env python3
"""Installed runtime. No third-party packages; never creates a direct route."""
import argparse
import contextlib
import ipaddress
import json
import os
from pathlib import Path
import select
import shlex
import shutil
import socket
import socketserver
import subprocess
import sys
import threading
import time


def state_dir():
    return Path(__file__).resolve().parent


def config():
    return json.loads((state_dir() / 'config.json').read_text())


def fail(message):
    raise RuntimeError(message)


def executable(name):
    value = shutil.which(name)
    if not value:
        fail(f'{name} is missing. Run setup.sh client again after installing it.')
    return str(Path(value).absolute())


def ssh_args(c):
    # Ignore wildcard SSH settings that could change the route or add forwards.
    proxy = f'{shlex.quote(c["nc"])} -X {c["upstream_type"]} -x 127.0.0.1:{c["upstream_port"]} %h %p'
    known_hosts = c['known_hosts'].replace('\\', '\\\\').replace('"', '\\"')
    return [c['ssh'], '-F', '/dev/null', '-NT', '-D', f'127.0.0.1:{c["socks_port"]}',
            '-p', str(c['home_port']), '-i', c['identity'], '-o', f'ProxyCommand={proxy}',
            '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ExitOnForwardFailure=yes',
            '-o', 'StrictHostKeyChecking=yes', '-o', f'UserKnownHostsFile="{known_hosts}"',
            '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30',
            '-o', 'ServerAliveCountMax=3', f'{c["home_user"]}@{c["home_host"]}']


def mihomo_yaml(c):
    # DNS follows the SOCKS hop. No DIRECT, UDP, or downloaded rule sets.
    return f'''mixed-port: {c['http_port']}
bind-address: 127.0.0.1
allow-lan: false
mode: rule
log-level: info
ipv6: false
external-controller: ''
proxies:
  - name: Home-SSH-SOCKS
    type: socks5
    server: 127.0.0.1
    port: {c['socks_port']}
    udp: false
rules:
  - MATCH,Home-SSH-SOCKS
dns:
  enable: true
  ipv6: false
  nameserver:
    - https://dns.google/dns-query#Home-SSH-SOCKS
hosts:
  dns.google: 8.8.8.8
'''


def proxy_env(c):
    url = f'http://127.0.0.1:{c["http_port"]}'
    env = os.environ.copy()
    for name in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
        env[name] = url
    env['NO_PROXY'] = env['no_proxy'] = 'localhost,127.0.0.1,::1'
    env['BROWSER'] = str(state_dir() / 'bin' / 'home-browser')
    env['CLAUDE_CODE_PROCESS_WRAPPER'] = json.dumps([str(state_dir() / 'bin' / 'home-run')])
    env['HOME_TUNNEL_ISOLATED'] = '1'
    for name in ('DBUS_SESSION_BUS_ADDRESS', 'DBUS_SYSTEM_BUS_ADDRESS'):
        env.pop(name, None)  # Do not delegate to an unwrapped desktop browser.
    return env


def pipe_sockets(a, b):
    a.settimeout(None)
    b.settimeout(None)
    streams = {a: b, b: a}
    while streams:
        for src in select.select(list(streams), [], [], 60)[0]:
            data = src.recv(65536)
            if data:
                streams[src].sendall(data)
            else:
                with contextlib.suppress(OSError):
                    streams[src].shutdown(socket.SHUT_WR)
                del streams[src]


class RelayHandler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            target = self.server.target
            if isinstance(target, str):
                peer = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                peer.settimeout(5)
                peer.connect(target)
            else:
                peer = socket.create_connection(target, timeout=5)
            with peer:
                pipe_sockets(self.request, peer)
        except OSError:
            pass  # Close the connection; never retry through another route.


class UnixRelay(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True


class TCPRelay(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def relay_host(c):
    sock = state_dir() / 'relay.sock'
    if sock.exists():
        with socket.socket(socket.AF_UNIX) as probe:
            try:
                probe.connect(str(sock))
            except OSError:
                sock.unlink()
            else:
                fail('The Linux relay is already running.')
    with UnixRelay(str(sock), RelayHandler) as server:
        os.chmod(sock, 0o600)
        server.target = ('127.0.0.1', c['http_port'])
        server.serve_forever()


def sandbox_profile(c):
    return f'''(version 1)
(allow default)
(deny network-outbound)
(allow network-outbound (remote tcp "localhost:{c['http_port']}"))
; Prevent LaunchServices from opening an existing, unsandboxed browser.
(deny process-exec (literal "/usr/bin/open"))
(deny mach-lookup (global-name "com.apple.coreservices.launchservicesd"))
(deny mach-lookup (global-name "com.apple.mDNSResponder"))
'''


def isolation_args(c, argv):
    if c['platform'] == 'Darwin':
        return ['/usr/bin/sandbox-exec', '-f', str(state_dir() / 'network.sb'), *argv]
    return [c['bwrap'], '--unshare-net', '--die-with-parent', '--bind', '/', '/',
            '--dev', '/dev', '--proc', '/proc', '--', c['python'], str(state_dir() / 'tunnel.py'),
            'inside', '--', *argv]


def inside(c, argv):
    # The namespace has only a loopback proxy backed by a Unix socket to host.
    # No external interfaces, DNS, IPv6, UDP, or arbitrary TCP route exist here.
    listener = TCPRelay(('127.0.0.1', c['http_port']), RelayHandler)
    parent = os.getpid()
    pid = os.fork()
    if pid == 0:
        listener.target = str(state_dir() / 'relay.sock')

        def watch_parent():
            while os.getppid() == parent:
                time.sleep(1)
            os._exit(0)

        threading.Thread(target=watch_parent, daemon=True).start()
        listener.serve_forever()
        os._exit(0)
    listener.server_close()
    env = proxy_env(c)
    env['HOME_TUNNEL_NETNS'] = os.readlink('/proc/self/ns/net')
    os.execvpe(argv[0], argv, env)


def port_open(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=0.5):
            return True
    except OSError:
        return False


def in_linux_namespace(c):
    return (c['platform'] == 'Linux'
            and os.environ.get('HOME_TUNNEL_NETNS') == os.readlink('/proc/self/ns/net')
            and all(name == 'lo' for _, name in socket.if_nameindex()))


def run_isolated(c, argv):
    if not argv:
        fail('Supply a command: home-run curl https://api.ipify.org')
    if not port_open(c['http_port']):
        fail('Home HTTP proxy is unavailable. Run home-tunnel doctor. Claude was not started.')
    env = proxy_env(c)
    if in_linux_namespace(c):
        os.execvpe(argv[0], argv, env)
    else:
        command = isolation_args(c, argv)
        os.execvpe(command[0], command, env)


def find_claude():
    wrapper = (state_dir() / 'bin').resolve()
    legacy = (Path.home() / '.config/ai-ssh-proxy/bin').resolve()
    for directory in os.environ.get('PATH', '').split(os.pathsep):
        if not directory or Path(directory).resolve() in (wrapper, legacy):
            continue
        candidate = Path(directory) / 'claude'
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate.absolute())
    fail('Claude Code is not installed or is absent from PATH. Install it, then open a new terminal.')


def browser_args(c, urls):
    browser = c.get('browser')
    if not browser or not Path(browser).is_file():
        fail('Install Chrome/Chromium, rerun setup.sh client, then run home-browser with the sign-in URL.')
    for url in urls:
        if not url.startswith(('https://', 'http://')):
            fail('home-browser accepts only http:// and https:// URLs.')
    return [browser, f'--user-data-dir={state_dir() / "browser-profile"}',
            f'--proxy-server=http://127.0.0.1:{c["http_port"]}', '--disable-quic',
            '--disable-background-networking',
            '--force-webrtc-ip-handling-policy=disable_non_proxied_udp',
            '--proxy-bypass-list=localhost;127.0.0.1;[::1]',
            '--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1',
            '--no-first-run', '--no-default-browser-check', *(urls or ['https://claude.ai'])]


def egress_ip(c, socks=False):
    proxy = f'{"socks5h" if socks else "http"}://127.0.0.1:{c["socks_port"] if socks else c["http_port"]}'
    result = subprocess.run([c['curl'], '--proxy', proxy, '--noproxy', '', '-4fsS',
                             '--connect-timeout', '5', '--max-time', '15', 'https://api.ipify.org'],
                            capture_output=True, text=True, timeout=18)
    if result.returncode:
        fail('Home egress check failed. Check Clash, home SSH, router and service logs.')
    return str(ipaddress.ip_address(result.stdout.strip()))


def start_browser(c, argv):
    if c['platform'] == 'Darwin':
        # Proxy flags cannot enforce all browser traffic. Chrome cannot start
        # under an inherited macOS sandbox without disabling its own sandbox.
        fail('Isolated browser launch is not supported on macOS. Use home-browser on a Linux client with a display (or an isolated Linux VM). No ordinary browser was opened. Home Mac mini SSH servers are supported.')
    args = browser_args(c, argv)
    run_isolated(c, args)


def doctor(c):
    problems = []
    for name, key in [('Clash upstream', 'upstream_port'), ('SSH SOCKS', 'socks_port'), ('Home HTTP', 'http_port')]:
        ok = port_open(c[key])
        print(f'{"OK" if ok else "FAIL"}: {name} on 127.0.0.1:{c[key]}')
        if not ok:
            problems.append(name)
    try:
        via_ssh, via_http = egress_ip(c, socks=True), egress_ip(c)
        if via_ssh != via_http:
            fail('SOCKS and HTTP egress IPs differ! Do not use Claude until fixed.')
        if c.get('expected_ip') and via_http != c['expected_ip']:
            fail(f'Home IP changed: expected {c["expected_ip"]}, got {via_http}. Verify at home and rerun setup.')
        print(f'OK: SSH SOCKS and HTTP both exit at {via_http}')
        if not c.get('expected_ip'):
            print('CHECK: compare this IP with the IP displayed on the home computer; no expected IP was saved.')
    except RuntimeError as e:
        problems.append(str(e))
        print(f'FAIL: {e}')
    probe = ('import socket,sys; s=socket.socket(); s.settimeout(2); '
             'r=s.connect_ex(("1.1.1.1",443)); sys.exit(0 if r else 9)')
    result = subprocess.run(isolation_args(c, [c['python'], '-c', probe]),
                            capture_output=True, text=True, env=proxy_env(c), timeout=10)
    if result.returncode:
        problems.append('isolation')
        print('FAIL: isolation probe failed: ' + result.stderr.strip()[:400])
    else:
        print('OK: isolated process cannot connect directly to a public IP')
    try:
        result = subprocess.run(isolation_args(c, [c['curl'], '--noproxy', '', '-4fsS',
                                '--max-time', '15', 'https://api.ipify.org']),
                                capture_output=True, text=True, env=proxy_env(c), timeout=20)
        if result.returncode or result.stdout.strip() != egress_ip(c):
            fail('Isolated proxy request failed or used a different IP.')
        print('OK: isolated process reaches the internet through home')
    except RuntimeError as e:
        problems.append(str(e))
        print(f'FAIL: {e}')
    print('Existing terminals, sessions and browsers must be restarted after setup.')
    if c['platform'] == 'Linux':
        print('Logs: journalctl --user -u home-tunnel-ssh -u home-tunnel-proxy -u home-tunnel-relay -n 60')
    else:
        print('Logs: ' + str(state_dir() / 'logs'))
    return 1 if problems else 0


def service_command(c, action):
    names = ['home-tunnel-ssh', 'home-tunnel-proxy']
    if c['platform'] == 'Linux':
        names.append('home-tunnel-relay')
        return subprocess.call(['systemctl', '--user', action, *[n + '.service' for n in names]])
    for name in names:
        label = 'local.' + name
        target = f'gui/{os.getuid()}/{label}'
        if action == 'stop':
            subprocess.run(['launchctl', 'bootout', target], check=False)
        elif action in ('start', 'restart'):
            if action == 'restart':
                subprocess.run(['launchctl', 'bootout', target], check=False, capture_output=True)
            subprocess.run(['launchctl', 'bootstrap', f'gui/{os.getuid()}',
                            str(Path.home() / 'Library/LaunchAgents' / (label + '.plist'))], check=True)
        else:
            subprocess.run(['launchctl', 'print', target], check=False)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['ssh', 'proxy', 'relay', 'inside', 'run', 'claude', 'browser',
                                         'doctor', 'start', 'stop', 'restart', 'status'])
    parser.add_argument('args', nargs=argparse.REMAINDER)
    options = parser.parse_args()
    argv = options.args[1:] if options.args[:1] == ['--'] else options.args
    c = config()
    action = options.action
    if action == 'ssh':
        os.execv(c['ssh'], ssh_args(c))
    if action == 'proxy':
        os.execv(c['mihomo'], [c['mihomo'], '-d', str(state_dir() / 'mihomo')])
    if action == 'relay':
        relay_host(c)
    elif action == 'inside':
        inside(c, argv)
    elif action == 'run':
        run_isolated(c, argv)
    elif action == 'claude':
        run_isolated(c, [find_claude(), *argv])
    elif action == 'browser':
        start_browser(c, argv)
    elif action == 'doctor':
        return doctor(c)
    elif action in ('start', 'stop', 'restart', 'status'):
        return service_command(c, action)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f'Home tunnel: {error}', file=sys.stderr)
        sys.exit(1)
