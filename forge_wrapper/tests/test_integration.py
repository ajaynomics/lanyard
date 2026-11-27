import contextlib
import hashlib
import io
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
import unittest
from unittest.mock import patch

from forge19 import Service
from protocol import Admission, Deadline, Problem
from upstream import Upstream
from fake_gitea import BASIC, BRANCH, PAT, REPO_ID, RUN_ID, TOKEN, Fixture, git
from test_denials import AGENT, CONTEXT, PR, PUSH, REPO, WORKSPACE, exchange


class Integration(unittest.TestCase):
    def setUp(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.forge = self.enterContext(Fixture(root))
        self.s = self.service()
        self.diff = dict(verb='diff', repo=REPO, base='main', head=BRANCH)
        self.runs = dict(verb='ci-runs', repo=REPO, head_sha=self.forge.head)
        self.jobs = dict(verb='ci-jobs', repo=REPO, run_id=RUN_ID)

    def service(self, *, repos=frozenset({REPO}), **options):
        f = self.forge
        return Service(os.geteuid(), AGENT, WORKSPACE, f.token, f.root, origin=f.origin, repos=repos, **options)

    def ok(self, op, keys):
        result, frame = exchange(self.s, op)
        self.assertEqual(set(result), {'status', 'verb', 'repo', *keys.split()})
        self.assertEqual((result['status'], result['verb'], result['repo']), ('ok', op['verb'], REPO))
        if 'bytes' in result:
            self.assertEqual(frame[:8], struct.pack('!Q', result['bytes']))
            self.assertEqual(len(frame[8:]), result['bytes'])
            self.assertEqual(hashlib.sha256(frame[8:]).hexdigest(), result['sha256'])
        else:
            self.assertEqual(frame, b'')
        return result, frame[8:]

    def negative(self, op, status, reason):
        self.assertEqual(exchange(self.s, op), (dict(status=status, verb=op['verb'],
                                                    repo=op['repo'], reason=reason), b''))

    def test_pr_exact_keys(self):
        row, _ = self.ok(PR, 'number state base head_ref head_sha mergeable title')
        self.assertEqual(row['head_sha'], self.forge.head)
        self.assertEqual(row['head_ref'], BRANCH)

    def test_real_git_patch_frame_and_counts(self):
        f = self.forge
        row, blob = self.ok(self.diff, 'base_sha head_sha files additions deletions bytes sha256')
        self.assertEqual((row['base_sha'], row['head_sha']), (f.base, f.head))
        self.assertEqual((row['files'], row['additions'], row['deletions']), (1, 1, 1))
        self.assertIn(b'\n-before\n+after\n', blob)
        self.assertIn(('POST', f'/{REPO}.git/git-upload-pack'), f.calls)
        self.assertEqual(f.refs(), f.initial_refs)

    def test_diff_compares_the_exact_two_trees_not_the_merge_base(self):
        f = self.forge
        git(f.source, 'checkout', '-q', 'main')
        diverged_base = f.change('base-only.txt', b'only on base\n')
        row, blob = self.ok(dict(self.diff, base=diverged_base, head=f.head),
                            'base_sha head_sha files additions deletions bytes sha256')
        self.assertEqual((row['base_sha'], row['head_sha']), (diverged_base, f.head))
        self.assertIn(b'deleted file mode', blob)
        self.assertIn(b'\n-only on base\n', blob)

    def test_full_sha_points(self):
        self.ok(dict(self.diff, base=self.forge.base, head=self.forge.head),
                'base_sha head_sha files additions deletions bytes sha256')

    def test_oversized_diff_has_no_frame(self):
        head = self.forge.change('big.txt', (b'A' * 120 + b'\n') * 3000)
        self.negative(dict(self.diff, head=head), 'refused', 'too_large')

    def test_ci_runs_and_jobs_exact_keys(self):
        result, _ = self.ok(self.runs, 'head_sha runs')
        run, = result['runs']
        self.assertEqual(set(run), {'run_id', 'workflow', 'event', 'status', 'conclusion', 'attempt'})
        self.assertEqual(run['run_id'], RUN_ID)
        result, _ = self.ok(self.jobs, 'run_id jobs')
        job, = result['jobs']
        self.assertEqual(set(job), {'job_id', 'name', 'status', 'conclusion', 'steps'})
        self.assertEqual(job['steps'], [dict(name='Check', conclusion='success')])

    def test_ci_jobs_reply_overflow(self):
        self.forge.job['steps'] = [dict(name='x' * 256, conclusion='success')] * 100
        self.negative(self.jobs, 'refused', 'too_large')

    def test_wrong_repo_run_never_requests_jobs(self):
        self.forge.run['repository_id'] = REPO_ID + 1
        self.negative(self.jobs, 'error', 'forge_error')
        self.assertEqual(len(self.forge.calls), 2)
        self.assertTrue(self.forge.calls[-1][1].endswith(f'/runs/{RUN_ID}'))
        self.negative(self.runs, 'error', 'forge_error')

    def test_wrong_run_job_is_not_returned(self):
        self.forge.job['run_id'] = RUN_ID + 1
        self.negative(self.jobs, 'error', 'forge_error')

    def test_secret_title_and_ci_step_refuse_whole_reply(self):
        f = self.forge
        for value in ('sk-' + 'z' * 24, 'ghp_' + 'Z' * 24, 'gho_' + 'z' * 24, 'gta_' + 'z' * 24,
                      'AKIA' + 'J' * 16, 'Authorization: Bearer synthetic',
                      'https://fixture:fake@example.invalid/foo', 'password="' + 'a' * 40 + '"',
                      '-----BEGIN PRIVATE KEY-----', PAT.decode(), BASIC.decode()):
            with self.subTest(value=value[:6]):
                f.pr['title'] = value
                self.negative(PR, 'refused', 'secret_shaped')
        f.job['steps'] = [dict(name='Authorization: synthetic')]
        self.negative(self.jobs, 'refused', 'secret_shaped')

    def test_secret_diff_refuses_whole_frame(self):
        head = self.forge.change('file.txt', b'ghp_' + b'X' * 30 + b'\n')
        self.negative(dict(self.diff, head=head), 'refused', 'secret_shaped')

    def test_control_character_in_diff_path(self):
        head = self.forge.change('unsafe\npath.txt', b'hello\n')
        self.negative(dict(self.diff, head=head), 'refused', 'unsafe_path')

    def test_disabled_verbs_and_foreign_context_never_touch_forge(self):
        f = self.forge
        for op in (PUSH, dict(verb='fetch', repo=REPO, ref='main', have=[]),
                   dict(verb='ci-log', repo=REPO, job_id=1, max_bytes=512, tail=False),
                   dict(verb='ci-artifact', repo=REPO, run_id=1, name='build')):
            self.negative(op, 'refused', 'verb')
        result, body = exchange(self.s, PR, context=dict(CONTEXT, agent_id=AGENT + 1))
        self.assertEqual((result['reason'], body), ('agent', b''))
        result, body = exchange(self.s, dict(PR, repo='another/private'))
        self.assertEqual((result['reason'], body), ('repo', b''))
        self.assertEqual(f.calls, [])
        self.assertEqual(f.refs(), f.initial_refs)

    def test_forge_timeout_is_single_attempt(self):
        self.s = self.service(read_seconds=.2)
        stopped = threading.Event()

        def block():
            stopped.wait(2)
            return self.forge.json(self.forge.meta)

        self.forge.routes[''] = block
        try:
            self.negative(PR, 'error', 'timeout')
            self.assertEqual(len(self.forge.calls), 1)
        finally:
            stopped.set()

    def test_dns_timeout_precedes_forge(self):
        self.s = self.service(read_seconds=.2)
        stopped = threading.Event()
        with patch('upstream.socket.getaddrinfo', side_effect=lambda *a, **kw: stopped.wait(2)):
            try:
                self.negative(PR, 'error', 'timeout')
                self.assertEqual(self.forge.calls, [])
            finally:
                stopped.set()

    def test_busy_does_not_make_second_forge_call(self):
        f = self.forge
        entered, resume = threading.Event(), threading.Event()

        def block():
            entered.set()
            resume.wait(2)
            return f.json(f.meta)

        f.routes[''] = block
        replies = []
        thread = threading.Thread(target=lambda: replies.append(exchange(self.s, PR)))
        thread.start()
        try:
            self.assertTrue(entered.wait(2))
            self.negative(PR, 'refused', 'busy')
            self.assertEqual(len(f.calls), 1)
        finally:
            resume.set()
            thread.join(5)
        self.assertEqual(replies[0][0]['status'], 'ok')

    def test_rolling_rate_limit_and_reset(self):
        clock = [1000]
        self.s = self.service(admission=Admission(clock=lambda: clock[0]))
        for _ in range(60):
            self.assertEqual(exchange(self.s, PR)[0]['status'], 'ok')
        expected = len(self.forge.calls)
        self.negative(PR, 'refused', 'rate')
        clock[0] += 599
        self.negative(PR, 'refused', 'rate')
        self.assertEqual(len(self.forge.calls), expected)
        clock[0] += 1
        self.assertEqual(exchange(self.s, PR)[0]['status'], 'ok')

    def test_api_and_git_cannot_follow_redirects(self):
        f = self.forge
        f.routes['/pulls/1'] = (302, [('Location', f.origin + '/redirected')], b'')
        self.negative(PR, 'error', 'forge_error')
        f.calls.clear()
        original = f.smart_git
        f.smart_git = lambda *args: (302, [('Location', f.origin + '/redirected')], b'')
        self.negative(self.diff, 'error', 'forge_error')
        f.smart_git = original
        self.assertNotIn(('GET', '/redirected'), f.calls)

    def test_token_file_rejection_precedes_forge(self):
        self.forge.token.chmod(0o644)
        self.negative(PR, 'refused', 'forge_error')
        self.assertEqual(self.forge.calls, [])

    def test_token_is_only_in_checked_file_and_private_git_fd(self):
        seen = []
        stderr = io.StringIO()
        original = subprocess.Popen

        def observe(argv, *args, **options):
            if options.get('pass_fds'):
                fd, = options['pass_fds']
                st = os.fstat(fd)
                self.assertEqual(st.st_mode & 0o7777, 0o600)
                self.assertEqual(st.st_uid, os.geteuid())
                self.assertIn(BASIC, os.pread(fd, 4096, 0))
                self.assertEqual(options['stderr'], subprocess.DEVNULL)
                child = original(argv, *args, **options)
                proc = Path('/proc') / str(child.pid)
                captured = (proc / 'cmdline').read_bytes() + (proc / 'environ').read_bytes()
                self.assertNotIn(PAT, captured)
                self.assertNotIn(BASIC, captured)
                seen.append(child.pid)
                return child
            return original(argv, *args, **options)

        with contextlib.redirect_stderr(stderr), patch('upstream.subprocess.Popen', side_effect=observe):
            row, frame = self.ok(self.diff, 'base_sha head_sha files additions deletions bytes sha256')
        self.assertEqual(len(seen), 2)
        for secret in (PAT, BASIC):
            self.assertNotIn(secret, repr(row).encode())
            self.assertNotIn(secret, frame)
            self.assertNotIn(secret, stderr.getvalue().encode())

    def test_outside_and_empty_allowlists_refuse_every_read_before_token_or_upstream(self):
        # If the request reached token custody it would fail with forge_error instead.
        self.forge.token.unlink()
        for repos in (frozenset({'fixture-org/elsewhere'}), frozenset()):
            self.s = self.service(repos=repos)
            for op in (PR, self.diff, self.runs, self.jobs):
                with self.subTest(repos=repos, verb=op['verb']):
                    self.negative(op, 'refused', 'repo')
        self.assertEqual(self.forge.calls, [])

    def test_upstream_independently_checks_the_same_exact_list_for_api_and_git(self):
        for repos in (frozenset({REPO}), frozenset()):
            upstream = Upstream(self.forge.origin, TOKEN, Deadline(5), repos)
            for repo in ('fixture-org/elsewhere', REPO.upper(), REPO + '/more', None):
                for action in (upstream.api, upstream.remote):
                    with self.subTest(repos=repos, repo=repo, action=action.__name__):
                        with self.assertRaisesRegex(Problem, '^repo$'):
                            action(repo)
            if repos:
                self.assertEqual(upstream.remote(REPO), f'{self.forge.origin}/{REPO}.git')
            else:
                for action in (upstream.api, upstream.remote):
                    with self.assertRaisesRegex(Problem, '^repo$'):
                        action(REPO)
        self.assertEqual(self.forge.calls, [])
