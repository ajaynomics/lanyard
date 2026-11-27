# Local forge bridge

Core offers no forge access by default. An install can bind one `forge` tool to
one persisted agent, one workspace, six exact repositories and one protected
local socket. The wrapper owns the forge credential. Core and the agent computer
never receive it.

## Enable one binding

Set these in both the Core web and job roles. The shipped values are blank.

| Setting | Value |
| --- | --- |
| `FORGE__AGENT_ID` | The allowed agent's persisted Rails ID |
| `FORGE__WORKSPACE_ID` | That agent's workspace's persisted Rails ID |
| `FORGE__REPOS` | Exactly six distinct `owner/repository` entries with the same owner, comma-separated |
| `FORGE__BRANCH_NAMESPACE` | The first segment of the approved push branch namespace, without a slash or wildcard |
| `FORGE__SOCKET_PATH` | Absolute path to the wrapper's Unix socket, ending in `.sock` |

This replaces `FORGE__REPO` and `FORGE__BRANCH`; those settings no longer
admit calls. Use the exact allowlist and namespace independently enforced by the
wrapper. Select **Forge** only for the bound agent. It counts as one tool. The
agent must be unpaused and its maker must still belong to the workspace. Core
checks this and the exact live call at admission and before dispatch. Other
agents, stale calls, and helpers cannot reach the wrapper. Core accepts one
queued or running forge call at a time per agent, across its conversations.

Keep the socket in a root-owned directory that Core cannot write. Core rejects
symlink or writable path components, verifies a root-owned `0600` or `0660`
socket and checks the connected peer's UID with Linux `SO_PEERCRED`. The wrapper
checks Core's peer UID too. Do not expose the socket on TCP or mount it into an
agent computer. Mount only the socket directory in Core, not the wrapper's
credential directory. Leave the binding off without this boundary.

## Stage A: metadata and inline reads

Every verb takes `verb` and one exact configured `repo`; unrelated arguments
are rejected before a socket opens. CI run and job IDs are scoped to that repo
by the wrapper. There is no `ci-status`, CI dispatch, merge or deploy action.

| Verb | Other inputs | Result |
| --- | --- | --- |
| `pr` | `number` (1 to 10,000,000) | State, base and head refs, head SHA, and mergeability. The title never goes to the model. |
| `diff` | `base`, `head` (branch or 40 lowercase hex) | Resolved SHAs, counts, bytes and SHA-256; a scan-clean UTF-8 patch excerpt marked as untrusted. The complete frame is capped at 256 KiB. The excerpt is smaller when needed to stay within the model result limit. Nothing is saved to the computer. |
| `ci-runs` | `head_sha` (40 lowercase hex) | At most 20 runs. |
| `ci-jobs` | `run_id` (1 to 10¹²) | At most 50 jobs and 100 steps per job. |
| `fetch`, `ci-log`, `ci-artifact`, `push` | Their respective typed wire inputs | **Forge file delivery is not available yet.** No socket opens and no wrapper call is made. |

References use ASCII letters, digits, `.`, `_`, `-`, `/`, start with a letter
or digit, and are at most 200 characters. They cannot contain `..`, `@{`, `//`,
a trailing slash or a component ending in `.lock`. Diff paths Core cannot
validate (including quoted paths and binary patches) are refused rather than
inlined. Secret-shaped text, malformed replies and mismatched digests are
refused as a whole; Core doesn't return a partially masked reply or log the
original text.

## Socket protocol

One connection, one UTF-8 JSON request line and one reply line, each at most
16 KiB including the newline. A successful diff reply is followed by an
unsigned 8-byte big-endian length and that many bytes; the length and SHA-256
must match the JSON header. The wrapper closes the connection after replying.
Core supplies the persisted IDs in `context`, separate from the validated
`operation`. The wire budgets are 30 seconds for reads and 120 seconds for
fetch/push when available. Only Stage A reads reach the wrapper. The sidecar's
10-second invocation callback is a separate timer: it waits on the queued job,
not one long HTTP request. The wrapper and Core do not retry the operation.

## Stage B: workspace files and writes (not available)

The next stage needs a bounded transfer to and from the bound computer. It
must validate lengths and digests, publish without overwrite, and take push
bundles from a fixed filename, not a model-provided path. The wire file limits
are 50 MiB for a bundle, 256 KiB for a CI log, and 10 MiB for a CI artifact.

The owner pre-approved pushes only in this exact lane. Forge does not ask
per push or take an approver note. This does not approve any other tool or
operation, and does not enable Stage A pushes.

A push must not force or delete. Its branch must start with the configured
namespace and have one to four further segments of 1–64 ASCII letters,
digits, `_` or `-`, each starting with a letter or digit. It takes a nonzero
40-hex `revision` and a nonzero 40-hex `expected_head` or `absent`. The wrapper
must verify the bundle, commit identity and ancestry, compare-and-swap on only
that exact ref, and read it back before confirming. A receipt includes the
Core-generated challenge, exact operation echo, and bundle size and digest.
A `refused` reply is the only automatic proof of no attempted ref update;
any error, including a failed compare-and-swap, keeps the uncertain hold.
The wrapper audits the attempt but Core must never log original bundle bytes
or credentials. None of this dispatches in Stage A.

Existing unresolved writes are not changed by Stage A. Once a call has
stopped, only the workspace owner may reconcile it after checking the wrapper
and forge. A local operator can load it through `workspace.invocations` and
record `invocation.resolve_forge_write!("applied", by: workspace.owner)` or
`"not_applied"`. This never resends it.
