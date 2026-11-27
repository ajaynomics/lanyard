"""Inherited Linux socket service for the read-only forge wrapper."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import os
from pathlib import Path
import re
import resource
import socket
import stat
import sys
import threading
import time

from operations import Operations
from protocol import (Admission, Deadline, LINE, MIB, REPO, Problem, Scanner, Wire, encode, match,
                      peer_uid, require, strict_json, validate)
from upstream import Upstream, https_origin, read_token

READ_SECONDS = 30


def echo(req, key, scan):
    op = req.get('operation') if type(req) is dict else None
    value = op.get(key) if type(op) is dict else None
    if type(value) is str:
        try:
            if scan.clean(value.encode()):
                return value
        except UnicodeError:
            pass
    return None


class Service:
    def __init__(self, uid, agent, workspace, token, scratch, *, origin, repos,
                 read_seconds=READ_SECONDS, admission=None):
        self.uid, self.agent, self.workspace = uid, agent, workspace
        self.token, self.scratch, self.origin, self.repos = token, scratch, origin, repos
        self.read_seconds = read_seconds
        self.admission = admission if admission is not None else Admission()

    def handle(self, conn):
        with conn:
            if peer_uid(conn) != self.uid:
                return
            deadline = Deadline(self.read_seconds)
            wire = Wire(conn, deadline)
            req, scanner = None, Scanner()
            admitted = False
            try:
                raw = wire.line()
                try:
                    req = strict_json(raw)
                except (ValueError, RecursionError):
                    raise Problem('bounds') from None
                op = validate(req, self.agent, self.workspace, self.repos)
                require(not wire.buf)
                self.admission.begin()
                admitted = True
                upstream = Upstream(self.origin, read_token(self.token), deadline, self.repos)
                scanner = upstream.scanner
                scanner.check(encode(req))
                fields, frame = Operations(self.scratch, upstream, op).run()
                reply = encode({'verb': op['verb'], 'repo': op['repo'], **fields})
                scanner.check(reply)
                require(len(reply) < LINE, 'too_large')
                try:
                    wire.send(reply, frame)
                except (OSError, Problem):
                    pass  # A partial reply must end at EOF, not with a second JSON line.
            except (BrokenPipeError, ConnectionResetError):
                pass
            except (Problem, TimeoutError, OSError, AttributeError, KeyError, ValueError, TypeError,
                    IndexError, RecursionError, OverflowError) as exc:
                if isinstance(exc, Problem):
                    status, reason = ('error' if exc.error else 'refused'), exc.reason
                elif isinstance(exc, TimeoutError):
                    status, reason = 'error', 'timeout'
                else:
                    status, reason = 'error', 'forge_error'
                # No exception details, inbound body, or credentials cross the boundary.
                v, r = (echo(req, key, scanner) for key in ('verb', 'repo'))
                failure = dict(status=status, verb=v, reason=reason)
                if r is not None:
                    failure['repo'] = r
                packed = encode(failure)
                if len(packed) >= LINE:
                    packed = encode(dict(status=status, verb=None, reason=reason))
                try:
                    conn.settimeout(max(0, min(0.1, deadline.end - time.monotonic())))
                    conn.sendall(packed + b'\n')
                except OSError:
                    pass
            finally:
                if admitted:
                    self.admission.lock.release()


def trusted_parents(path):
    require(path.is_absolute() and '..' not in path.parts, 'forge_error')
    for directory in path.parents:
        st = directory.lstat()
        require(stat.S_ISDIR(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022, 'forge_error')


def parse_repos(data):
    try:
        repos = strict_json(data)
    except (ValueError, RecursionError):
        raise Problem('forge_error') from None
    require(type(repos) is list and all(match(REPO, repo) and len(repo) <= 160 for repo in repos),
            'forge_error')
    allowed = frozenset(repos)
    require(len(allowed) == len(repos), 'forge_error')
    return allowed


def read_repos(path):
    trusted_parents(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as config:
        st = os.fstat(config.fileno())
        require(stat.S_ISREG(st.st_mode) and st.st_uid == 0 and not st.st_mode & 0o022, 'forge_error')
        data = config.read(LINE + 1)
    require(len(data) <= LINE, 'forge_error')
    return parse_repos(data)


def root_listener(fd):
    listener = socket.socket(fileno=fd)
    try:
        os.set_inheritable(fd, False)
        require(listener.family == socket.AF_UNIX and listener.type == socket.SOCK_STREAM
                and listener.getsockopt(socket.SOL_SOCKET, socket.SO_ACCEPTCONN)
                and peer_uid(listener) == 0, 'forge_error')
        name = listener.getsockname()
        require(type(name) is str, 'forge_error')
        entry = Path(name)
        require(entry.as_posix() == name, 'forge_error')
        trusted_parents(entry)
        st = entry.lstat()
        require(stat.S_ISSOCK(st.st_mode) and st.st_uid == 0 and stat.S_IMODE(st.st_mode) in (0o600, 0o660),
                'forge_error')
        return listener
    except (OSError, Problem, ValueError):
        listener.close()
        raise


def serve(listener, service):
    # Allow a bounded number of peers to get busy/refusal while one call is in progress.
    slots = threading.BoundedSemaphore(16)

    def handle(conn):
        try:
            service.handle(conn)
        finally:
            slots.release()

    with ThreadPoolExecutor(max_workers=16) as workers:
        while True:
            conn, _ = listener.accept()
            if not slots.acquire(blocking=False):
                conn.close()
                continue
            workers.submit(handle, conn)


def decimal_id(value, minimum, maximum):
    if not re.fullmatch(r'0|[1-9][0-9]{0,18}', value) or not minimum <= int(value) <= maximum:
        raise argparse.ArgumentTypeError(f'expected a decimal integer in {minimum}..{maximum}')
    return int(value)


def https_arg(value):
    if not https_origin(value):
        raise argparse.ArgumentTypeError('expected an HTTPS origin without path or userinfo')
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description='Serve the read-only forge protocol on a systemd socket',
                                     allow_abbrev=False)
    parser.add_argument('--core-uid', type=lambda value: decimal_id(value, 0, 2**32 - 2), required=True)
    parser.add_argument('--agent-id', type=lambda value: decimal_id(value, 1, 2**63 - 1), required=True)
    parser.add_argument('--workspace-id', type=lambda value: decimal_id(value, 1, 2**63 - 1), required=True)
    parser.add_argument('--repos-file', type=Path, required=True)
    parser.add_argument('--origin', type=https_arg, required=True)
    parser.add_argument('--token-file', type=Path, required=True)
    parser.add_argument('--scratch', type=Path, required=True)
    args = parser.parse_args(argv)
    os.umask(0o077)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    limit = 128 * MIB if hard == resource.RLIM_INFINITY else min(hard, 128 * MIB)
    resource.setrlimit(resource.RLIMIT_FSIZE, (limit, hard))
    try:
        require(os.geteuid() != 0, 'forge_error')
        require(os.environ.get('LISTEN_PID') == str(os.getpid()) and os.environ.get('LISTEN_FDS') == '1',
                'forge_error')
        scratch = args.scratch.lstat()
        require(stat.S_ISDIR(scratch.st_mode) and scratch.st_uid == os.geteuid() and
                stat.S_IMODE(scratch.st_mode) == 0o700, 'forge_error')
        repos = read_repos(args.repos_file)
        service = Service(args.core_uid, args.agent_id, args.workspace_id, args.token_file, args.scratch,
                          origin=args.origin, repos=repos)
        with root_listener(3) as listener:
            serve(listener, service)
    except (OSError, Problem, ValueError):
        print('forge-wrapper: unavailable', file=sys.stderr)
        return 1
    return 0
