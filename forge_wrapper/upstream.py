"""The only outbound transports: Gitea GET and Git smart HTTPS."""
import base64
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
import fcntl
import http.client
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import ssl
import stat
import subprocess
import threading
from urllib.parse import urlsplit

from protocol import KIB, MIB, Problem, Scanner, require, strict_json

HOST_LABEL = r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
HTTPS_ORIGIN = re.compile(rf'https://(?:{HOST_LABEL}\.)*{HOST_LABEL}(?::[0-9]{{1,5}})?')
METADATA = 2 * MIB
PRIVATE = re.compile(rb'[A-Za-z0-9_.-]{1,64}:[A-Za-z0-9_-]{20,128}\n?')
DNS = ThreadPoolExecutor(max_workers=1, thread_name_prefix='forge-dns')


def https_origin(value):
    if type(value) is not str or len(value) > 267 or not HTTPS_ORIGIN.fullmatch(value):
        return False
    try:
        url = urlsplit(value)
        return len(url.hostname) <= 253 and url.port != 0
    except ValueError:
        return False


def read_token(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as token:
            st = os.fstat(token.fileno())
            require(stat.S_ISREG(st.st_mode) and st.st_uid == os.geteuid()
                    and stat.S_IMODE(st.st_mode) == 0o600 and st.st_nlink == 1, 'forge_error')
            data = token.read(256)
    except OSError:
        raise Problem('forge_error') from None
    require(PRIVATE.fullmatch(data), 'forge_error')
    return data.removesuffix(b'\n')


class Upstream:
    def __init__(self, origin, credentials, clock, repos):
        self.origin = origin
        self.url = urlsplit(origin)
        if not https_origin(origin) and not re.fullmatch(r'http://127\.0\.0\.1:[0-9]{1,5}', origin):
            raise ValueError('invalid forge origin')
        self.token = credentials.split(b':', 1)[1]
        self.basic = base64.b64encode(credentials)
        self.scanner = Scanner(self.token, self.basic, base64.b64encode(self.token))
        self.clock, self.repos = clock, repos

    def remote(self, repo):
        require(type(repo) is str and repo in self.repos, 'repo')
        return self.origin + '/' + repo + '.git'

    @contextmanager
    def git_config(self):
        # Bind what was checked to what Git reads. No pathname re-open of the source token,
        # disk copy, credential helper, prompt or secret value in argv/environment.
        fd = os.memfd_create('forge-https', os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING)
        try:
            os.fchmod(fd, 0o600)
            config = (b'[http "' + self.origin.encode() + b'/"]\n'
                      b'  extraHeader = Authorization: Basic ' + self.basic + b'\n')
            require(os.write(fd, config) == len(config), 'forge_error')
            fcntl.fcntl(fd, fcntl.F_ADD_SEALS,
                        fcntl.F_SEAL_WRITE | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SEAL)
            yield fd
        finally:
            os.close(fd)

    def connect(self, host, port):
        # Resolver calls can outlast socket timeouts. Keep at most one running,
        # and never let it consume the admitted call's entire thread indefinitely.
        lookup = DNS.submit(socket.getaddrinfo, host, port, type=socket.SOCK_STREAM)
        try:
            addresses = lookup.result(timeout=self.clock.left())
        finally:
            lookup.cancel()
        for family, kind, proto, _, address in addresses:
            conn = socket.socket(family, kind, proto)
            try:
                conn.settimeout(self.clock.left())
                conn.connect(address)
                conn.settimeout(self.clock.left())
                if self.url.scheme == 'https':
                    conn = ssl.create_default_context().wrap_socket(conn, server_hostname=host)
                return conn
            except ssl.SSLError:
                conn.close()
                raise
            except OSError:
                conn.close()
                self.clock.left()
            except Problem:
                conn.close()
                raise
        raise Problem('forge_error', error=True)

    def get(self, path, limit):
        host = self.url.hostname
        port = self.url.port or 443
        connection = http.client.HTTPConnection(host, port, timeout=self.clock.left())
        headers = {'Accept-Encoding': 'identity', 'Connection': 'close',
                   'Authorization': 'token ' + self.token.decode('ascii')}

        def interrupt(sock):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

        timer = None
        try:
            sock = connection.sock = self.connect(host, port)
            timer = threading.Timer(self.clock.left(), interrupt, (sock,))
            timer.daemon = True
            timer.start()
            connection.request('GET', path, headers=headers)
            with connection.getresponse() as response:
                self.clock.left()
                require(response.status != 404, 'not_found')
                require(response.status == 200 and response.getheader('Content-Encoding', 'identity') == 'identity',
                        'forge_error', error=True)
                if response.length is not None:
                    require(0 <= response.length <= limit, 'too_large')
                remaining = response.length
                data = bytearray()
                while len(data) <= limit:
                    self.clock.left()
                    chunk = response.read1(min(64 * KIB, limit + 1 - len(data)))
                    if not chunk:
                        break
                    data.extend(chunk)
                self.clock.left()
                require(len(data) <= limit, 'too_large')
                require(remaining is None or remaining == len(data), 'forge_error', error=True)
                return bytes(data)
        except TimeoutError:
            raise Problem('timeout', error=True) from None
        except (OSError, http.client.HTTPException):
            self.clock.left()
            raise Problem('forge_error', error=True) from None
        finally:
            if timer is not None:
                timer.cancel()
            connection.close()

    def api(self, repo, suffix=''):
        require(type(repo) is str and repo in self.repos, 'repo')
        raw = self.get('/api/v1/repos/' + repo + suffix, METADATA)
        require(not any(value in raw for value in self.scanner.credentials), 'secret_shaped')
        try:
            return strict_json(raw)
        except (ValueError, RecursionError):
            raise Problem('forge_error', error=True) from None


GIT_ENV = {
    'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent', 'LC_ALL': 'C',
    'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1',
    'GIT_TERMINAL_PROMPT': '0', 'GIT_NO_REPLACE_OBJECTS': '1', 'GIT_LITERAL_PATHSPECS': '1',
}
GIT = (
    '/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'credential.helper=',
    '-c', 'http.followRedirects=false', '-c', 'http.proxy=', '-c', 'http.sslVerify=true',
    '-c', 'transfer.fsckObjects=true', '-c', 'fetch.writeCommitGraph=false',
    '-c', 'gc.auto=0', '-c', 'maintenance.auto=false', '-c', 'core.quotePath=true',
    '-c', 'pack.threads=1', '-c', 'http.maxRequests=1',
)


class Git:
    def __init__(self, work, upstream):
        self.work = Path(work)
        self.upstream = upstream

    def run(self, *args, network=False, limit=METADATA):
        env = GIT_ENV | {'GIT_ALLOW_PROTOCOL': self.upstream.url.scheme if network else ''}
        if network:
            with self.upstream.git_config() as fd:
                env['GIT_CONFIG_GLOBAL'] = f'/proc/self/fd/{fd}'
                return self.execute(args, env, (fd,), limit)
        return self.execute(args, env, (), limit)

    def execute(self, args, env, fds, limit):
        clock = self.upstream.clock
        clock.left()
        with subprocess.Popen((*GIT, *args), cwd=self.work, env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              pass_fds=fds, start_new_session=True) as proc:
            try:
                output = bytearray()
                with selectors.DefaultSelector() as poll:
                    poll.register(proc.stdout, selectors.EVENT_READ)
                    while poll.select(clock.left()):
                        chunk = os.read(proc.stdout.fileno(), min(64 * KIB, limit + 1 - len(output)))
                        if not chunk:
                            break
                        output.extend(chunk)
                        require(len(output) <= limit, 'too_large')
                    else:
                        raise Problem('timeout', error=True)
                rc = proc.wait(timeout=clock.left())
                require(rc == 0, 'forge_error', error=True)
                return bytes(output)
            except subprocess.TimeoutExpired:
                raise Problem('timeout', error=True) from None
            finally:
                if proc.poll() is None:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def init(self):
        self.run('init', '--bare', '--quiet', '--template=', '--object-format=sha1')

    def fetch(self, source, name, destination):
        self.run('fetch', '--quiet', '--depth=1', '--no-tags', '--no-recurse-submodules',
                 '--no-write-fetch-head', '--', source, f'{name}:{destination}', network=True)
        return self.run('rev-parse', '--verify', destination + '^{commit}').decode('ascii').strip()
