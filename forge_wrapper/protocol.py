"""Strict framing, admission and reply validation for the forge wrapper."""
from collections import deque
import hashlib
import json
import re
import socket
import struct
import threading
import time
import unicodedata

KIB = 1024
MIB = KIB**2
LINE = 16 * KIB
PATCH = 256 * KIB
REPO = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]*/[A-Za-z0-9][A-Za-z0-9_-]*', re.ASCII)
SHA = re.compile(r'(?!0{40}$)[0-9a-f]{40}', re.ASCII)
REF = re.compile(r'[A-Za-z0-9][A-Za-z0-9._/-]{0,199}', re.ASCII)
CTX = frozenset(('agent_id', 'workspace_id', 'conversation_id', 'invocation_id', 'task_id', 'call_id'))
# Stage A is read only. There is no parser or dispatcher for the other draft-2 verbs.
FIELDS = {'diff': ('base', 'head'), 'pr': ('number',), 'ci-runs': ('head_sha',), 'ci-jobs': ('run_id',)}
REASON = frozenset(('agent', 'peer', 'repo', 'branch', 'verb', 'bounds', 'busy', 'rate',
                    'too_large', 'secret_shaped', 'unsafe_path', 'not_found', 'moved',
                    'not_ff', 'identity', 'bundle', 'forge_error', 'timeout', 'unknown'))


class Problem(Exception):
    def __init__(self, reason, *, error=False):
        assert reason in REASON
        self.reason, self.error = reason, error
        super().__init__(reason)


def require(condition, reason='bounds', *, error=False):
    if not condition:
        raise Problem(reason, error=error)


def match(pattern, value):
    return type(value) is str and pattern.fullmatch(value) is not None


def number(value, maximum=10**12):
    return type(value) is int and 0 < value <= maximum


def branch_name(value):
    return (match(REF, value) and not value.startswith('refs/') and '..' not in value
            and all(p and not p.startswith('.') and not p.endswith('.lock') for p in value.split('/'))
            and not value.endswith('.'))


def ref(value):
    return match(SHA, value) or (value != '0' * 40 and branch_name(value))


def text(value, limit):
    return (type(value) is str and 0 < len(value) <= limit and
            not any(unicodedata.category(c).startswith('C') for c in value))


def path(value):
    require(type(value) is str and len(value) <= 4096 and '\\' not in value and ':' not in value
            and all(text(p, 255) and p.rstrip(' .').casefold() not in ('', '.', '..', '.git', 'git~1')
                    and p == p.rstrip(' .') for p in value.split('/')), 'unsafe_path')


def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate key')
        result[key] = value
    return result


def bad_constant(_value):
    raise ValueError('not JSON')


DECODER = json.JSONDecoder(object_pairs_hook=unique, parse_constant=bad_constant)


def strict_json(data):
    return DECODER.decode(data.decode('utf-8'))


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode()


def validate(req, agent, workspace, repos):
    require(type(req) is dict)
    ctx, op = req.get('context'), req.get('operation')
    require(type(ctx) is dict and type(ctx.get('agent_id')) is int and ctx['agent_id'] == agent
            and type(ctx.get('workspace_id')) is int and ctx['workspace_id'] == workspace, 'agent')
    require(ctx.keys() == CTX and all(number(ctx[k], 2**63 - 1) for k in ('invocation_id', 'conversation_id'))
            and all(text(ctx[k], 256) for k in ('task_id', 'call_id')))
    require(type(op) is dict)
    verb, repo = op.get('verb'), op.get('repo')
    require(type(repo) is str and repo in repos, 'repo')
    require(type(verb) is str and verb in FIELDS, 'verb')
    require(op.keys() == {'verb', 'repo', *FIELDS[verb]})
    require(req.keys() == {'context', 'operation'})
    if verb == 'diff':
        require(ref(op['base']) and ref(op['head']))
    elif verb == 'pr':
        require(number(op['number'], 10**7))
    elif verb == 'ci-runs':
        require(match(SHA, op['head_sha']))
    elif verb == 'ci-jobs':
        require(number(op['run_id']))
    return op


SECRET = re.compile(
    rb'-----BEGIN [A-Z0-9 ]{1,60}-----'
    rb'|(?:sk-|ghp_|gho_|gta_)[A-Za-z0-9_-]{12,}'
    rb'|\bAKIA[A-Z0-9]{16}\b'
    rb'|\bAuthorization\s*:'
    rb'|(?<![a-z0-9+.-])[a-z][a-z0-9+.-]{0,31}://[^/\s<>"@]{1,4096}@'
    rb'|(?:token|password|secret)["\047]?\s*(?:[=:]\s*)?["\047]?[0-9a-f]{40}(?![0-9a-f])'
    rb'|(?<![0-9a-f])[0-9a-f]{40}["\047]?\s*(?:[=:]\s*)?["\047]?(?:token|password|secret)\b',
    re.IGNORECASE | re.ASCII)
ANSI = re.compile(rb'\x1b\[[0-?]*[ -/]*[@-~]')


class Scanner:
    def __init__(self, *credentials):
        self.credentials = credentials

    def clean(self, data):
        # Scan the original bytes and a view without terminal escapes or UTF-16 padding.
        for view in (data, ANSI.sub(b'', data.replace(b'\0', b''))):
            if SECRET.search(view) or any(value in view for value in self.credentials):
                return False
        return True

    def check(self, data):
        require(self.clean(data), 'secret_shaped')


def digest(data):
    return {'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()}


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds
    def left(self):
        remaining = self.end - time.monotonic()
        if remaining <= 0:
            raise Problem('timeout', error=True)
        return remaining


class Wire:
    def __init__(self, sock, clock):
        self.sock, self.clock = sock, clock
        self.buf = bytearray()

    def line(self):
        while True:
            index = self.buf.find(b'\n')
            if index >= 0:
                line = bytes(self.buf[:index])
                del self.buf[:index + 1]
                return line
            require(len(self.buf) < LINE)
            self.sock.settimeout(self.clock.left())
            chunk = self.sock.recv(LINE - len(self.buf))
            require(chunk)
            self.buf.extend(chunk)

    def send(self, reply, frame=None):
        self.sock.settimeout(self.clock.left())
        self.sock.sendall(reply + b'\n')
        if frame is not None:
            self.sock.settimeout(self.clock.left())
            self.sock.sendall(struct.pack('!Q', len(frame)))
            self.sock.settimeout(self.clock.left())
            self.sock.sendall(frame)


def peer_uid(sock):
    return struct.unpack('=iII', sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]


class Admission:
    def __init__(self, clock=time.monotonic):
        self.lock = threading.Lock()
        self.now = clock
        self.calls = deque()

    def begin(self):
        require(self.lock.acquire(blocking=False), 'busy')
        try:
            now = self.now()
            while self.calls and self.calls[0] <= now - 600:
                self.calls.popleft()
            require(len(self.calls) < 60, 'rate')
            self.calls.append(now)
        except Problem:
            self.lock.release()
            raise
