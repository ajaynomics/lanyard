"""Loopback Gitea-shaped API and real smart HTTP against a bare SHA-1 repo."""
import base64
from contextlib import AbstractContextManager, ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import threading
from urllib.parse import urlsplit

from test_denials import REPO

TOKEN = b'fixture:ZNOTAREALTOKEN123456789abc'
PAT = TOKEN.split(b':')[1]
BASIC = base64.b64encode(TOKEN)
GIT_ENV = {'PATH': '/usr/bin:/bin', 'HOME': '/nonexistent', 'LC_ALL': 'C',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
           'GIT_ALLOW_PROTOCOL': 'file'}
BRANCH = 'compatible/topic'
REPO_ID = 71
RUN_ID = 42
JOB_ID = 43


def git(path, *args):
    return subprocess.run(('/usr/bin/git', '-C', str(path), '-c', 'user.name=Fixture',
                           '-c', 'user.email=fixture@example.invalid', *args),
                          check=True, capture_output=True, env=GIT_ENV, timeout=10).stdout.strip()


class Fixture(AbstractContextManager):
    def __init__(self, root):
        self.root = root
        self.token = root / 'token'
        self.token.touch(mode=0o600)
        self.token.write_bytes(TOKEN + b'\n')
        self.source = root / 'source'
        self.remote = root / 'remote.git'
        git(root, 'init', '-q', '--object-format=sha1', '-b', 'main', str(self.source))
        self.base = self.commit('file.txt', b'before\n')
        git(self.source, 'checkout', '-qb', BRANCH)
        self.head = self.commit('file.txt', b'after\n')
        git(root, 'clone', '--bare', '-q', str(self.source), str(self.remote))
        self.initial_refs = self.refs()
        self.calls = []
        self.routes = {}
        self.api = f'/api/v1/repos/{REPO}'
        self.exit = ExitStack()
        self.meta = {'full_name': REPO, 'id': REPO_ID, 'default_branch': 'main'}
        self.pr = dict(number=1, state='open', mergeable=True, title='Clean title',
                       base=dict(repo=self.meta, ref='main'), head=dict(ref=BRANCH, sha=self.head))
        self.run = dict(id=RUN_ID, repository_id=REPO_ID, head_sha=self.head, run_attempt=1,
                        path='.github/workflows/ci.yml', event='pull_request',
                        status='completed', conclusion='success')
        self.job = dict(id=JOB_ID, run_id=RUN_ID, name='test', head_sha=self.head,
                        status='completed', conclusion='success',
                        steps=[dict(name='Check', conclusion='success', number=1)])

    def commit(self, file, data):
        (self.source / file).write_bytes(data)
        git(self.source, 'add', '--', file)
        git(self.source, 'commit', '-qm', 'Fixture change')
        return git(self.source, 'rev-parse', 'HEAD').decode()

    def change(self, file, data):
        head = self.commit(file, data)
        git(self.remote, 'fetch', '-q', str(self.source), 'HEAD:refs/heads/scratch-test')
        return head

    def refs(self):
        return git(self.remote, 'for-each-ref', '--format=%(refname) %(objectname)')

    def __enter__(self):
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self):
                size = int(self.headers.get('Content-Length', '0'))
                if size > 1024**2:
                    self.send_error(413)
                    return
                code, headers, data = fixture.dispatch(self.command, self.path, self.headers, self.rfile.read(size))
                try:
                    self.send_response(code)
                    for key, value in headers:
                        self.send_header(key, value)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            do_GET = do_POST = reply

        server = self.exit.enter_context(ThreadingHTTPServer(('127.0.0.1', 0), Handler))
        thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        thread.start()
        self.exit.callback(thread.join)
        self.exit.callback(server.shutdown)
        self.origin = f'http://127.0.0.1:{server.server_port}'
        return self

    def __exit__(self, *exc):
        return self.exit.__exit__(*exc)

    def dispatch(self, method, target, headers, body):
        self.calls.append((method, target))
        url = urlsplit(target)
        git_path = f'/{REPO}.git/'
        if url.path.startswith(git_path):
            if headers.get('Authorization', '').encode() != b'Basic ' + BASIC:
                return 401, [], b''
            return self.smart_git(method, url.path.removeprefix(git_path), url.query, body, headers)
        if method != 'GET' or headers.get('Authorization', '').encode() != b'token ' + PAT:
            return 401, [], b''
        if not url.path.startswith(self.api):
            return 404, [], b''
        suffix = url.path.removeprefix(self.api)
        override = self.routes.get(suffix)
        if override is not None:
            return override() if callable(override) else override
        defaults = {
            '': self.meta, '/pulls/1': self.pr,
            '/actions/runs': {'workflow_runs': [self.run]},
            f'/actions/runs/{RUN_ID}': self.run,
            f'/actions/runs/{RUN_ID}/jobs': {'jobs': [self.job]},
        }
        return self.json(defaults[suffix]) if suffix in defaults else (404, [], b'')

    @staticmethod
    def json(data):
        return 200, [('Content-Type', 'application/json')], json.dumps(data).encode()

    def smart_git(self, method, suffix, query, body, headers):
        if (method, suffix, query) != ('GET', 'info/refs', 'service=git-upload-pack') and (
                method, suffix, query) != ('POST', 'git-upload-pack', ''):
            return 403, [], b''
        env = GIT_ENV | {'REQUEST_METHOD': method, 'PATH_INFO': '/remote.git/' + suffix,
                         'QUERY_STRING': query, 'GIT_PROJECT_ROOT': str(self.root), 'GIT_HTTP_EXPORT_ALL': '1',
                         'CONTENT_TYPE': headers.get('Content-Type', ''), 'CONTENT_LENGTH': str(len(body)),
                         'GIT_PROTOCOL': headers.get('Git-Protocol', '')}
        proc = subprocess.run(['/usr/bin/git', 'http-backend'], input=body, capture_output=True,
                              env=env, timeout=10, check=True)
        hdrs, reply = proc.stdout.split(b'\r\n\r\n', 1)
        pairs = [tuple(line.split(': ', 1)) for line in hdrs.decode().split('\r\n')]
        code = int(next((v.split()[0] for k, v in pairs if k == 'Status'), '200'))
        return code, [(k, v) for k, v in pairs if k not in ('Status', 'Content-Length')], reply
