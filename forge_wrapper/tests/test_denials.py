import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch

if os.environ.get('FORGE_TEST_RED') == '1':
    from permissive import Service, read_token
else:
    from forge19 import Service, read_token

REPO = 'fixture-org/project'
AGENT, WORKSPACE = 123, 456
CONTEXT = dict(agent_id=AGENT, workspace_id=WORKSPACE, conversation_id=7, invocation_id=8,
               task_id='task-1', call_id='call-1')
PUSH = dict(verb='push', repo=REPO, branch='fixture/topic',
            expected_head='absent', revision='1' * 40)
PR = dict(verb='pr', repo=REPO, number=1)
HOSTILE = ('fixture/../main', 'refs/heads/main', '+fixture/x', 'fixture/x:main',
           ':refs/tags/v1', 'fixture/x\\x00', 'fixture/x\\n', 'fixture/x\\t',
           'fixture/x\\r', 'fixture/x\\x7f', 'fixture/é', 'fixture/ⅹ',
           'fixture/x y', 'fixture', 'fixture/', 'fixture//x', 'fixture/x.lock',
           'fixture/@{u}', 'fixture/a/b/c/d/e', 'fixture/x%2fmain', 'Fixture/x',
           'main', 'fixture/x/', 'fixture/..', 'fixture/_x', 'fixture/' + 'x' * 65)


def envelope(op, context=CONTEXT):
    req = dict(operation=op, context=context)
    if op['verb'] == 'push':
        req['challenge'] = 'a' * 32
    return req


def exchange(service, op=PR, *, context=CONTEXT, body=None, raw=None):
    client, server = socket.socketpair()
    thread = threading.Thread(target=service.handle, args=(server,))
    thread.start()
    try:
        with client:
            # The wrapper bounds each exchange by its own read deadline. Real git work on a
            # loaded host can outlast a shorter guess while the wrapper is still on time.
            client.settimeout(service.read_seconds + 1)
            if raw is None:
                raw = json.dumps(envelope(op, context)).encode() + b'\n'
            if body is not None:
                raw += struct.pack('!Q', len(body)) + body
            try:
                client.sendall(raw)
                client.shutdown(socket.SHUT_WR)
            except OSError:
                pass
            with client.makefile('rb') as reader:
                try:
                    line = reader.readline()
                except ConnectionResetError:
                    return None, b''
                try:
                    rest = reader.read()
                except ConnectionResetError:
                    rest = b''
                return json.loads(line) if line else None, rest
    finally:
        thread.join(5)
        if thread.is_alive():
            raise AssertionError('wrapper did not stop')


class Denials(unittest.TestCase):
    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.token = self.root / 'token'
        self.token.touch(mode=0o600)
        self.token.write_bytes(b'fixture:ZNOTAREALTOKEN123456789abc\n')
        self.audit = self.root / 'audit'
        self.audit.touch(mode=0o600)
        self.service = self.make_service(os.geteuid())

    def make_service(self, uid):
        return Service(uid, AGENT, WORKSPACE, self.token, self.root, origin='http://127.0.0.1:1',
                       repos=frozenset({REPO}))

    def deny(self, reason, op=PR, **kwargs):
        reply, frame = exchange(self.service, op, **kwargs)
        self.assertIsNotNone(reply)
        self.assertEqual((reply['status'], reply['reason']), ('refused', reason))
        self.assertEqual(frame, b'')
        self.assertEqual(self.audit.read_bytes(), b'')

    def test_wrong_kernel_peer_never_gets_reply(self):
        self.assertEqual(exchange(self.make_service(os.geteuid() + 1)), (None, b''))

    def test_wrong_agent_or_workspace(self):
        for ctx in (dict(CONTEXT, agent_id=AGENT + 1), dict(CONTEXT, workspace_id=WORKSPACE + 1),
                    dict(CONTEXT, workspace_id=True), dict(CONTEXT, agent_id=str(AGENT))):
            self.deny('agent', context=ctx)

    def test_wrong_repo(self):
        self.deny('repo', dict(PR, repo='fixture-org/other'))

    def test_hostile_branches_do_not_enable_push(self):
        for branch in HOSTILE:
            with self.subTest(branch=branch):
                self.deny('verb', dict(PUSH, branch=branch), body=b'bad')

    def test_unknown_verb_and_extra_fields(self):
        self.deny('verb', dict(PR, verb='ci-status'))
        self.deny('bounds', dict(PR, path='/etc/passwd'))

    def test_stage_b_is_disabled_even_with_valid_arguments(self):
        for op in (PUSH, dict(verb='fetch', repo=REPO, ref='main', have=[]),
                   dict(verb='ci-log', repo=REPO, job_id=1, max_bytes=512, tail=False),
                   dict(verb='ci-artifact', repo=REPO, run_id=1, name='build')):
            with self.subTest(verb=op['verb']):
                self.deny('verb', op)

    def test_oversized_request_line(self):
        self.deny('bounds', raw=json.dumps(envelope(PR)).encode() + b' ' * 16384 + b'\n')

    def test_duplicate_json_keys_are_refused(self):
        raw = json.dumps(envelope(PR)).encode().replace(b'"number": 1', b'"number": 1, "number": 1')
        self.deny('bounds', raw=raw + b'\n')

    def test_extra_data_on_read_is_refused(self):
        self.deny('bounds', raw=json.dumps(envelope(PR)).encode() + b'\nextra')

    def test_push_is_refused_without_consuming_a_frame(self):
        self.deny('verb', PUSH)
        line = json.dumps(envelope(PUSH)).encode() + b'\n'
        self.deny('verb', raw=line + struct.pack('!Q', 50 * 1024**2 + 1))

    def test_wrong_token_mode(self):
        self.token.chmod(0o644)
        with self.assertRaises(Exception) as context:
            read_token(self.token)
        self.assertEqual(str(context.exception), 'forge_error')

    def test_token_symlink(self):
        link = self.root / 'link'
        link.symlink_to(self.token)
        with self.assertRaises(Exception) as context:
            read_token(link)
        self.assertEqual(str(context.exception), 'forge_error')

    def test_wrong_token_owner(self):
        with patch('os.geteuid', return_value=self.token.stat().st_uid + 1):
            with self.assertRaises(Exception) as context:
                read_token(self.token)
        self.assertEqual(str(context.exception), 'forge_error')
