import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
import setup
import tunnel


def sample():
    return dict(platform='Darwin' if sys.platform == 'darwin' else 'Linux',
                python=sys.executable, ssh='/usr/bin/ssh', nc='/usr/bin/nc',
                curl=shutil.which('curl'), mihomo='/not/used/mihomo', identity='/key with spaces',
                known_hosts='/known hosts', home_host='home.example.net', home_user='alex',
                home_port=22222, upstream_port=27890, upstream_type='connect', http_port=27891,
                socks_port=20880, bwrap=shutil.which('bwrap') or '', browser='/fake/chrome', expected_ip='')


class ConfigTests(unittest.TestCase):
    def test_generate_only_previews_both_platforms(self):
        with tempfile.TemporaryDirectory(prefix='home preview ') as d:
            for system in ['Darwin', 'Linux']:
                destination = Path(d) / system
                result = subprocess.run([sys.executable, str(ROOT / 'setup.py'), 'client',
                    '--generate-only', '--noninteractive', '--target-os', system,
                    '--home-host', 'home.example.net', '--home-user', 'alex',
                    '--mihomo', '/not/installed/mihomo', '--output', str(destination)],
                    capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue((destination / 'config.json').is_file())
                self.assertTrue((destination / 'claude-settings.preview.json').is_file())
                self.assertTrue((destination / 'bin/home-tunnel').is_file())
                self.assertIn('No services', result.stdout)

    def test_no_direct_route(self):
        text = tunnel.mihomo_yaml(sample())
        self.assertNotIn('DIRECT', text)
        self.assertNotIn('fallback', text)
        self.assertIn('MATCH,Home-SSH-SOCKS', text)
        self.assertIn('https://dns.google/dns-query#Home-SSH-SOCKS', text)
        self.assertIn('udp: false', text)

    def test_ssh_uses_only_explicit_clash_proxy(self):
        args = tunnel.ssh_args(sample())
        self.assertEqual(args[args.index('-F') + 1], '/dev/null')
        self.assertIn('StrictHostKeyChecking=yes', args)
        self.assertIn('BatchMode=yes', args)
        proxy = next(v for v in args if v.startswith('ProxyCommand='))
        self.assertIn('-X connect -x 127.0.0.1:27890 %h %p', proxy)
        c = sample()
        c['upstream_type'] = '5'
        self.assertTrue(any('-X 5 ' in v for v in tunnel.ssh_args(c)))

    def test_reject_shell_metacharacters(self):
        for text in ['host;touch /tmp/oops', '$(id)', '-oProxyCommand=evil', 'host\nPort 22', 'https://home']:
            with self.assertRaises(RuntimeError):
                setup.valid_host(text)
        self.assertEqual(setup.valid_host('2001:db8::1'), '2001:db8::1')

    def test_settings_preserve_existing_and_backup(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'settings.json'
            p.write_text(json.dumps({'permissions': {'allow': ['Read']}, 'env': {'EXISTING': 'yes', 'NO_PROXY': '*'}}))
            merged = setup.merge_settings(p, sample(), Path(d))
            value = json.loads(merged)
            self.assertEqual(value['permissions'], {'allow': ['Read']})
            self.assertEqual(value['env']['EXISTING'], 'yes')
            self.assertEqual(value['env']['NO_PROXY'], 'localhost,127.0.0.1,::1')
            setup.write(p, merged)
            self.assertEqual(len(list(Path(d).glob('*.bak-*'))), 1)
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            setup.write(p, merged)
            self.assertEqual(len(list(Path(d).glob('*.bak-*'))), 1)

    def test_malformed_settings_not_overwritten(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / 'settings.json'
            p.write_text('broken json')
            with self.assertRaises(ValueError):
                setup.merge_settings(p, sample(), Path(d))
            self.assertEqual(p.read_text(), 'broken json')

    def test_alias_migration_and_idempotency(self):
        old = '# my settings\n# >>> AI CLI proxy aliases — tunnel via home >>>\nalias claude=old\n# <<< AI CLI proxy aliases <<<\n'
        once = setup.merge_shell(old, Path('/a path'))
        self.assertEqual(setup.merge_shell(once, Path('/a path')), once)
        self.assertNotIn('alias claude=old', once)
        self.assertIn('# my settings', once)
        self.assertIn('unalias claude', once)

    def test_service_serialization(self):
        c = sample()
        c['platform'] = 'Darwin'
        files = setup.services(c, Path('/a path/with & characters'))
        p = plistlib.loads(files['local.home-tunnel-ssh.plist'])
        self.assertEqual(p['ProgramArguments'][1], '/a path/with & characters/tunnel.py')
        c['platform'] = 'Linux'
        files = setup.services(c, Path('/a path/100%'))
        self.assertIn('100%%', files['home-tunnel-ssh.service'])
        self.assertIn('Restart=always', files['home-tunnel-ssh.service'])

    def test_ssh_known_hosts_path_keeps_spaces(self):
        args = tunnel.ssh_args(sample())
        self.assertIn('UserKnownHostsFile="/known hosts"', args)

    def test_closed_proxy_refuses_to_start_program(self):
        from unittest.mock import patch
        with patch.object(tunnel, 'port_open', return_value=False):
            with self.assertRaisesRegex(RuntimeError, 'unavailable'):
                tunnel.run_isolated(sample(), ['/bin/echo', 'should never run'])

    def test_environment_overrides_all_spellings(self):
        from unittest.mock import patch
        with patch.dict(os.environ, {'https_proxy': 'http://wrong', 'NO_PROXY': '*'}):
            env = tunnel.proxy_env(sample())
        for k in ['https_proxy', 'HTTPS_PROXY', 'ALL_PROXY', 'all_proxy', 'HTTP_PROXY', 'http_proxy']:
            self.assertEqual(env[k], 'http://127.0.0.1:27891')
        self.assertNotEqual(env['NO_PROXY'], '*')

    def test_find_claude_skips_legacy_and_current_wrappers(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            current = home / 'current'
            legacy = home / '.config/ai-ssh-proxy/bin'
            real = home / 'real'
            for path in [current / 'bin', legacy, real]:
                path.mkdir(parents=True)
                (path / 'claude').write_text('#!/bin/sh\nexit 0\n')
                (path / 'claude').chmod(0o700)
            with patch.object(tunnel, 'state_dir', return_value=current), patch.object(Path, 'home', return_value=home), patch.dict(os.environ, {'PATH': os.pathsep.join(map(str, [current / 'bin', legacy, real]))}):
                self.assertEqual(tunnel.find_claude(), str(real / 'claude'))

    def test_browser_urls_cannot_inject_flags(self):
        with tempfile.NamedTemporaryFile() as f:
            c = sample()
            c['browser'] = f.name
            with self.assertRaises(RuntimeError):
                tunnel.browser_args(c, ['--no-sandbox'])
            args = tunnel.browser_args(c, ['https://claude.ai'])
            self.assertIn('--disable-quic', args)
            self.assertIn('--force-webrtc-ip-handling-policy=disable_non_proxied_udp', args)
            self.assertIn('--host-resolver-rules=MAP * ~NOTFOUND, EXCLUDE localhost, EXCLUDE 127.0.0.1', args)

    def test_mac_browser_fails_closed_without_exec(self):
        from unittest.mock import patch
        c = sample()
        c['platform'] = 'Darwin'
        with patch.object(os, 'execv') as execute:
            with self.assertRaisesRegex(RuntimeError, 'not supported on macOS'):
                tunnel.start_browser(c, ['https://claude.ai'])
            execute.assert_not_called()


class IsolationTests(unittest.TestCase):
    """Real OS isolation with a disposable fake HTTP proxy, no public requests."""
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='home-tunnel-test-')
        cls.path = Path(cls.directory.name)
        cls.server = socket.socket()
        cls.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        cls.server.bind(('127.0.0.1', 0))
        cls.server.listen()
        cls.c = sample()
        cls.c['http_port'] = cls.server.getsockname()[1]
        cls.c['browser'] = ''
        setup.render(cls.c, cls.path)
        cls.requests = []
        cls.stop_server = threading.Event()

        def serve():
            while not cls.stop_server.is_set():
                try:
                    conn, _ = cls.server.accept()
                except OSError:
                    return
                with conn:
                    data = conn.recv(8192)
                    if data:
                        cls.requests.append(data)
                        conn.sendall(b'HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nhome')

        threading.Thread(target=serve, daemon=True).start()
        cls.relay = None
        if cls.c['platform'] == 'Linux':
            if not cls.c['bwrap']:
                raise unittest.SkipTest('bubblewrap is not installed')
            probe = subprocess.run([cls.c['bwrap'], '--unshare-net', '--bind', '/', '/', '--', '/bin/true'], capture_output=True)
            if probe.returncode:
                raise unittest.SkipTest('unprivileged network namespaces unavailable: ' + probe.stderr.decode())
            cls.relay = subprocess.Popen([sys.executable, str(cls.path / 'tunnel.py'), 'relay'])
            import time
            for _ in range(100):
                if (cls.path / 'relay.sock').exists():
                    break
                time.sleep(0.02)

    @classmethod
    def tearDownClass(cls):
        if cls.relay:
            cls.relay.terminate()
            cls.relay.wait(timeout=5)
        cls.stop_server.set()
        cls.server.close()
        cls.directory.cleanup()

    def invoke(self, *args):
        return subprocess.run([sys.executable, str(self.path / 'tunnel.py'), 'run', '--', *args],
                              capture_output=True, text=True, timeout=15)

    def test_proxy_request_reaches_only_fixture(self):
        result = self.invoke(self.c['curl'], '--max-time', '5', '--noproxy', '', '-sS', 'http://does-not-exist.invalid/probe')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'home')
        self.assertTrue(any(b'http://does-not-exist.invalid/probe' in r for r in self.requests))

    def test_ignored_proxy_cannot_connect_direct_ipv4(self):
        code = 'import socket,sys; s=socket.socket(); s.settimeout(2); r=s.connect_ex(("1.1.1.1",443)); sys.exit(9 if r==0 else 0)'
        result = self.invoke(sys.executable, '-c', code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ipv6_and_udp_blocked(self):
        code = '''import socket
for family, target in [(socket.AF_INET, ('1.1.1.1', 53)), (socket.AF_INET6, ('2606:4700:4700::1111', 53))]:
    try:
        s=socket.socket(family, socket.SOCK_DGRAM)
        s.sendto(b'probe', target)
    except OSError:
        continue
    raise SystemExit(9)
'''
        result = self.invoke(sys.executable, '-c', code)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_nested_wrapper_preserves_route_and_arguments(self):
        result = self.invoke(str(self.path / 'bin/home-run'), sys.executable, '-c',
                             'import sys; print(sys.argv[1])', 'spaces $() ; literal')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), 'spaces $() ; literal')

    def test_other_local_proxy_cannot_be_used(self):
        with socket.socket() as other:
            other.bind(('127.0.0.1', 0))
            other.listen()
            code = f'import socket,sys; s=socket.socket(); s.settimeout(1); sys.exit(9 if s.connect_ex(("127.0.0.1",{other.getsockname()[1]}))==0 else 0)'
            result = self.invoke(sys.executable, '-c', code)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
