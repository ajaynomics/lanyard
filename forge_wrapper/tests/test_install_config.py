import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from forge19 import parse_repos, read_repos, root_listener, trusted_parents
from protocol import Problem, peer_uid

BIN = Path(__file__).resolve().parents[1] / 'bin/forge-wrapper'
ARGS = {
    '--core-uid': '1000', '--agent-id': '123', '--workspace-id': '456',
    '--origin': 'https://forge.example.invalid', '--repos-file': '/unused/repos.json',
    '--token-file': '/unused/token', '--scratch': '/unused/scratch',
}


class InstallConfig(unittest.TestCase):
    def run_service(self, args):
        return subprocess.run(
            [str(BIN), *(item for pair in args.items() for item in pair)],
            env={'PATH': '/usr/bin:/bin'}, capture_output=True, timeout=5,
        )

    def test_agent_and_workspace_are_required_command_line_arguments(self):
        for flag in ('--agent-id', '--workspace-id'):
            with self.subTest(flag=flag):
                args = ARGS.copy()
                del args[flag]
                proc = self.run_service(args)
                self.assertEqual(proc.returncode, 2)
                self.assertIn(f'required: {flag}'.encode(), proc.stderr)

    def test_agent_and_workspace_are_bounded_ascii_decimal_ids(self):
        for flag in ('--agent-id', '--workspace-id'):
            for invalid in ('0', '-2', '+1', '01', ' 1', '1 ', '١', '1_2', str(2**63)):
                with self.subTest(flag=flag, value=invalid):
                    proc = self.run_service(ARGS | {flag: invalid})
                    self.assertEqual(proc.returncode, 2)
                    self.assertIn(f'argument {flag}: expected a decimal integer'.encode(), proc.stderr)

    def test_origin_does_not_accept_userinfo_path_non_tls_or_bad_port(self):
        for invalid in ('https://user@forge.example.invalid', 'https://forge.example.invalid/path',
                        'http://127.0.0.1:1234', 'https://forge.example.invalid:65536'):
            with self.subTest(origin=invalid):
                proc = self.run_service(ARGS | {'--origin': invalid})
                self.assertEqual(proc.returncode, 2)
                self.assertIn(b'argument --origin: expected an HTTPS origin', proc.stderr)

    def test_valid_arguments_without_systemd_activation_fail_closed(self):
        proc = self.run_service(ARGS | {'--agent-id': '1', '--workspace-id': str(2**63 - 1)})
        self.assertEqual((proc.returncode, proc.stdout, proc.stderr),
                         (1, b'', b'forge-wrapper: unavailable\n'))

    def test_read_repos_returns_one_immutable_literal_list_including_empty(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'repos.json'
            config.write_bytes(b'["fixture-org/project", "another-org/other-project"]\n')
            # The filesystem ownership itself is tested separately. CI uses a
            # normal temporary directory, not the real root-owned install path.
            with patch('forge19.trusted_parents'), patch('forge19.os.fstat', return_value=type(
                    'FileStat', (), {'st_mode': 0o100644, 'st_uid': 0})()):
                self.assertEqual(read_repos(config), frozenset({'fixture-org/project', 'another-org/other-project'}))
                config.write_bytes(b'[]\n')
                self.assertEqual(read_repos(config), frozenset())
                config.write_bytes(b'[]' + b' ' * 16384)
                with self.assertRaisesRegex(Problem, '^forge_error$'):
                    read_repos(config)

    def test_duplicate_and_malformed_repositories_are_refused(self):
        for invalid in (b'["fixture-org/project","fixture-org/project"]', b'{}', b'[1]', b'null',
                        b'[""]', b'[" fixture-org/project"]', b'["fixture-org/project "]',
                        b'["org/*"]', b'["org/.."]', b'["org/%2e"]', b'["org/project/more"]',
                        b'["https://org/project"]', b'["org/project\\n"]', b'["org/\\u0430"]',
                        b'["' + b'x' * 159 + b'/z"]', b'["org/repo",]', b'["org/\xff"]'):
            with self.subTest(value=invalid):
                with self.assertRaisesRegex(Problem, '^forge_error$'):
                    parse_repos(invalid)

    def test_config_rejects_symlink_and_writable_regular_file(self):
        with tempfile.TemporaryDirectory() as root:
            config = Path(root) / 'repos.json'
            config.write_bytes(b'[]')
            alias = Path(root) / 'alias.json'
            alias.symlink_to(config)
            config.chmod(0o666)
            with patch('forge19.trusted_parents'):
                with self.assertRaises(OSError):
                    read_repos(alias)
                with self.assertRaisesRegex(Problem, '^forge_error$'):
                    read_repos(config)

    def test_unsafe_ancestors_are_refused(self):
        with tempfile.TemporaryDirectory() as root:
            parent = Path(root) / 'directory'
            parent.mkdir(mode=0o777)
            parent.chmod(0o777)
            with self.assertRaisesRegex(Problem, '^forge_error$'):
                trusted_parents(parent / 'socket')
            alias = Path(root) / 'alias'
            alias.symlink_to(parent, target_is_directory=True)
            with self.assertRaisesRegex(Problem, '^forge_error$'):
                trusted_parents(alias / 'socket')


class Listener(unittest.TestCase):
    def test_requires_a_listening_pathname_unix_stream(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as unbound, \
             socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as datagram, \
             socket.socket(socket.AF_INET, socket.SOCK_STREAM) as inet:
            inet.bind(('127.0.0.1', 0))
            inet.listen()
            for sock in (unbound, datagram, inet):
                with self.subTest(family=sock.family, type=sock.type):
                    fd = os.dup(sock.fileno())
                    with self.assertRaisesRegex(Problem, '^forge_error$'):
                        root_listener(fd)
                    with self.assertRaises(OSError):
                        os.fstat(fd)

    def test_authorized_kernel_listener_still_needs_a_safe_socket_entry(self):
        with tempfile.TemporaryDirectory() as root, socket.socket(socket.AF_UNIX) as sock:
            path = Path(root) / 'forge.sock'
            sock.bind(str(path))
            sock.listen()
            path.chmod(0o666)
            with patch('forge19.peer_uid', return_value=0), patch('forge19.trusted_parents'):
                with self.assertRaisesRegex(Problem, '^forge_error$'):
                    root_listener(os.dup(sock.fileno()))
                path.chmod(0o660)
                if os.geteuid() == 0:
                    with root_listener(os.dup(sock.fileno())) as listener:
                        self.assertTrue(listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN))
                else:
                    with self.assertRaisesRegex(Problem, '^forge_error$'):
                        root_listener(os.dup(sock.fileno()))

    def test_check_uses_kernel_listener_uid_even_if_path_checks_pass(self):
        with tempfile.TemporaryDirectory() as root, socket.socket(socket.AF_UNIX) as sock:
            path = Path(root) / 'forge.sock'
            sock.bind(str(path))
            sock.listen()
            path.chmod(0o660)
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(str(path))
                self.assertEqual(peer_uid(client), os.geteuid())
                self.assertEqual(peer_uid(sock), os.geteuid())
            # Simulate a non-root kernel listener on a correctly owned path.
            with patch('forge19.peer_uid', return_value=1000), patch('forge19.trusted_parents') as check:
                with self.assertRaisesRegex(Problem, '^forge_error$'):
                    root_listener(os.dup(sock.fileno()))
                check.assert_not_called()
