# Forge wrapper wire contract — Stage A

This is the read-only subset of the wire protocol. Stages that accept or
return other payloads are not part of this wrapper.

## Transport and admission

- One pathname AF_UNIX stream, one request per connection. The systemd
  system manager creates the root-owned listener and hands it to the
  non-root wrapper. The socket mode is 0600 or 0660; all ancestor directories
  are root-owned, real directories and not group- or other-writable.
- Before sending the request, Core checks the path with `lstat` and checks
  that `SO_PEERCRED` on the connected socket reports UID 0. The wrapper
  checks that `SO_PEERCRED` on the accepted connection reports its configured
  Core web/job UID; a different peer is disconnected without reading.
- Request and reply are each one UTF-8 JSON line, at most 16 KiB including
  the newline. Only a successful `diff` appends a frame: an unsigned 8-byte
  big-endian length followed by that many patch bytes. Core verifies the
  length, the 256 KiB bound, the SHA-256 digest and EOF.
- The wrapper allows one admitted call at a time, at most 60 admitted calls
  per rolling ten minutes, and a 30-second deadline per request. It does not
  retry.

## Requests

`{"context": {...}, "operation": {"verb": "...", "repo": "...", ...}}`

Core supplies the persisted `agent_id`, `workspace_id`, `conversation_id`,
`invocation_id`, `task_id` and `call_id`. The model supplies only the operation.
Agent and workspace IDs must be JSON integers equal to the explicit service
arguments or the wrapper returns `refused/agent`. The conversation and
invocation IDs are positive integers up to 2^63−1. The task and call IDs
are nonempty strings of at most 256 characters, without control characters.

The service reads a single exact, case-sensitive repository allowlist on
startup. No built-in repositories, wildcard matching or normalization.
An empty list denies every repository. The wrapper refuses an unlisted
repository with `refused/repo` before reading credentials or starting Git
or HTTPS. Both upstream entry points recheck membership in the same list.

| Verb | Additional operation fields |
|---|---|
| `pr` | `number`: positive integer ≤ 10^7 |
| `diff` | `base`, `head`: branch name or full nonzero lowercase 40-hex commit ID |
| `ci-runs` | `head_sha`: nonzero lowercase 40-hex commit ID |
| `ci-jobs` | `run_id`: positive integer ≤ 10^12, verified against the repository |

Branch names start with an ASCII letter or digit and use only ASCII letters,
digits, dots, underscores, slashes and hyphens (max 200 characters). No
`refs/` prefix, `..`, empty or dot-leading segments, `.lock` suffix on a
segment, or trailing dot. Extra keys or duplicate JSON keys are invalid.
All other verbs are refused, including `fetch`, `ci-log`, `ci-artifact`
and `push`. No challenge or request frame is accepted.

## Replies

Success has `status: "ok"`, `verb`, `repo`, and the exact additional keys below.
Failure has `status: "refused"` or `"error"`, `verb`, `reason`, and `repo` when
available and safe to echo; it never has a frame. A refused read can have
already contacted upstream (for example, if the returned patch is unsafe).

| Verb | Additional reply fields |
|---|---|
| `pr` | `number, state, base, head_ref, head_sha, mergeable, title` |
| `diff` | `base_sha, head_sha, files, additions, deletions, bytes, sha256`, followed by the patch frame |
| `ci-runs` | `head_sha, runs` (up to 20 entries: `run_id, workflow, event, status, conclusion, attempt`) |
| `ci-jobs` | `run_id, jobs` (up to 50 entries: `job_id, name, status, conclusion, steps`; up to 100 steps, each `name, conclusion`) |

PR states are `open`, `closed` and `merged`; `mergeable` is a boolean or null.
CI status is `queued`, `in_progress`, `completed`, `waiting` or `unknown`;
conclusion is `success`, `failure`, `cancelled`, `skipped`, `neutral`,
`timed_out`, `action_required` or null. The Stage A response reasons are
`agent`, `repo`, `verb`, `bounds`, `busy`, `rate`, `too_large`,
`secret_shaped`, `unsafe_path`, `not_found`, `forge_error` and `timeout`.

Diff compares the exact trees of the resolved commits (`git diff base..head`),
not a merge base. It has no external diff drivers or submodule recursion.
Unsafe paths, secret-shaped replies and oversized replies are refused as
a whole, never masked or partially returned.
