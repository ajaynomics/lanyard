"""Read-only projections from the allowed repositories."""
import tempfile

from protocol import PATCH, SHA, Problem, branch_name, digest, match, number, path, require, text
from upstream import Git

STATUSES = frozenset(('queued', 'in_progress', 'completed', 'waiting', 'unknown'))
CONCLUSIONS = frozenset(('success', 'failure', 'cancelled', 'skipped', 'neutral', 'timed_out', 'action_required'))
DIFF_OPTIONS = ('--no-ext-diff', '--no-textconv', '--no-renames', '--no-color', '--ignore-submodules=all')

def valid(value, rule):
    require(rule, 'forge_error', error=True)
    return value


def clean_text(scan, value, limit):
    require(type(value) is str, 'forge_error', error=True)
    scan.check(value.encode())
    return valid(value, text(value, limit))


def fields_status(record):
    status, conclusion = record['status'], record.get('conclusion')
    valid(status, status in STATUSES)
    valid(conclusion, conclusion is None or conclusion in CONCLUSIONS)
    return {'status': status, 'conclusion': conclusion}


def validate_paths(raw):
    require(not raw or raw.endswith(b'\0'), 'unsafe_path')
    for name in raw.split(b'\0')[:-1]:
        try:
            path(name.decode())
        except UnicodeError:
            raise Problem('unsafe_path') from None



class Operations:
    def __init__(self, scratch, upstream, operation):
        self.scratch, self.up, self.op = scratch, upstream, operation
        self.repo = operation['repo']
        self.scan = upstream.scanner

    def get(self, suffix=''):
        return self.up.api(self.repo, suffix)

    def run(self):
        meta = self.get()
        self.repo_id = meta['id']
        valid(self.repo_id, number(self.repo_id) and meta['full_name'] == self.repo)
        verb = self.op['verb']
        if verb == 'diff':
            with tempfile.TemporaryDirectory(dir=self.scratch) as work:
                git = Git(work, self.up)
                git.init()
                result, frame = self.diff(git)
        else:
            result, frame = {'pr': self.pr, 'ci-runs': self.ci_runs, 'ci-jobs': self.ci_jobs}[verb](), None
        return {'status': 'ok', **result}, frame

    def fetch_point(self, git, point, dest):
        name = point if match(SHA, point) else 'refs/heads/' + point
        tip = git.fetch(self.up.remote(self.repo), name, dest)
        return valid(tip, match(SHA, tip) and (not match(SHA, point) or tip == point))

    def diff(self, git):
        base = self.fetch_point(git, self.op['base'], 'refs/heads/forge-base')
        tip = self.fetch_point(git, self.op['head'], 'refs/heads/forge-head')
        # Check changed paths separately, without Git's quoted display form.
        options = (*DIFF_OPTIONS, base, tip, '--')
        paths = git.run('diff', '--name-only', '-z', *options, limit=PATCH)
        validate_paths(paths)
        self.scan.check(paths)
        raw = git.run('diff', '--numstat', '-z', *options, limit=PATCH)
        stats = [row.split(b'\t', 2) for row in raw.split(b'\0')[:-1]]
        patch = git.run('diff', '--patch', *options, limit=PATCH)
        self.scan.check(patch)
        return {'base_sha': base, 'head_sha': tip, 'files': len(stats),
                'additions': sum(int(a) for a, _, _ in stats if a != b'-'),
                'deletions': sum(int(d) for _, d, _ in stats if d != b'-'),
                **digest(patch)}, patch

    def pr(self):
        number = self.op['number']
        row = self.get(f'/pulls/{number}')
        title = clean_text(self.scan, row['title'], 200)
        base, head = row['base'], row['head']
        valid(base, base['repo']['id'] == self.repo_id and base['repo']['full_name'] == self.repo)
        state = 'merged' if row.get('merged') is True else row['state']
        valid(row, row['number'] == number and state in ('open', 'closed', 'merged')
              and branch_name(base['ref']) and branch_name(head['ref']) and match(SHA, head['sha'])
              and (row['mergeable'] is None or type(row['mergeable']) is bool))
        return dict(number=number, state=state, base=base['ref'], head_ref=head['ref'],
                    head_sha=head['sha'], mergeable=row['mergeable'], title=title)

    def owns_run(self, row, run_id):
        valid(row, number(run_id) and row['id'] == run_id and row['repository_id'] == self.repo_id
              and match(SHA, row['head_sha']))
        return row

    def run_info(self, run_id):
        return self.owns_run(self.get(f'/actions/runs/{run_id}'), run_id)

    def ci_runs(self):
        head = self.op['head_sha']
        rows = self.get(f'/actions/runs?head_sha={head}&page=1&limit=20')['workflow_runs']
        valid(rows, type(rows) is list and len(rows) <= 20)
        runs = []
        for row in rows:
            self.owns_run(row, row['id'])
            valid(row, row['head_sha'] == head and number(row['run_attempt']))
            runs.append(dict(run_id=row['id'], workflow=clean_text(self.scan, row['path'], 512),
                             event=clean_text(self.scan, row['event'], 128),
                             attempt=row['run_attempt'], **fields_status(row)))
        return dict(head_sha=head, runs=runs)

    def ci_jobs(self):
        run_id = self.op['run_id']
        run = self.run_info(run_id)
        rows = self.get(f'/actions/runs/{run_id}/jobs?page=1&limit=50')['jobs']
        valid(rows, type(rows) is list and len(rows) <= 50)
        jobs = []
        for row in rows:
            valid(row, number(row['id']) and row['run_id'] == run_id and row['head_sha'] == run['head_sha'])
            step_rows = row.get('steps') or []
            valid(step_rows, type(step_rows) is list and len(step_rows) <= 100)
            steps = []
            for step in step_rows:
                conclusion = step.get('conclusion')
                steps.append(dict(name=clean_text(self.scan, step['name'], 512),
                                  conclusion=valid(conclusion, conclusion is None or conclusion in CONCLUSIONS)))
            jobs.append(dict(job_id=row['id'], name=clean_text(self.scan, row['name'], 512),
                             **fields_status(row), steps=steps))
        return dict(run_id=run_id, jobs=jobs)
