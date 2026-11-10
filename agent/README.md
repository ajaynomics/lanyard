# Pi Durable sidecar

A private Node process that runs the published `@earendil-works/pi-durable@1.5.2`
harness for the Rails application. Rails owns identity, authorisation, domain
state, every agent's definition and every business tool. The sidecar listens on
loopback only and holds no business rules.

## Agents and tools

Each submission from Rails carries the agent's definition: `{ instructions, model,
thinkingLevel, tools: [{ name, description, parameters }], capabilities, computer, digest }`
(`docs/design/CONTRACT.md`). The digest
is SHA-256 of the canonical JSON of everything else, and must match. The sidecar
installs each definition once as extension `bot.<digest>` (the name predates the rename and is kept), records which
definition each conversation runs (in its own store, so a restart reinstalls
them without asking Rails), and reconfigures a conversation from its next
request when the digest changes. A definition must name an offered model, and
its tools may not shadow the sidecar's own (`read`, `write`, `edit`, `bash`,
`visit_website`, `codemode`, `subagent`, `web_search`). Conversations never see
another agent's tools.

`capabilities` switches the sidecar's built-in abilities per agent: `codemode`
(one script calls several tools), `subagents` (a helper conversation) and
`web_search`. One table in `runtime.mjs` maps each to its extension; an agent gets
only those it names. There is no way to load extension code of an agent's own.

A helper (`subagent.mjs`) is a conversation the `subagent` call owns. Its
creating commit copies the scope and the definition mapping and records the
root conversation and call in its scope (`App.root`), so its tool calls reach
Rails as the root's (`callId` `<helper call>/<own call>`), its model requests
reserve the root's `maxRequests`, and it shares the root's computer folder.
The doorbell searches the owned tree, so a person can answer a helper's
question. The helper's running calls are copied into the call's details and
appear in the root's frames.

Web search (`web-search.mjs`) ports `pi-web-search`'s requests: Anthropic
Messages with `web_search_20250305` on `claude-haiku-5-5`, as Claude Code when
the token is the subscription's (bearer, Claude Code's betas, user agent and
system block, and our billing block), and Codex Responses with `web_search` on
the ChatGPT subscription. The token comes from the same credential reader as
the chat's (`productionModels`), never the environment. A search reserves one
of the run's `maxRequests` and reports its usage.

Every tool in a definition is a forwarder: it POSTs the call to Rails
(`/agent/invocations`, signed with the digest of the whole call) and returns
Rails' result. It is replay-safe because Rails' ledger answers a replayed call
from what it recorded. A tool declared with `files` (an argument of paths and
its limits) first reads those files from the agent's computer and posts each
to `/agent/uploads` (`attachments.mjs`); a replay reads them again. When Rails answers `waiting` (a person must approve or
answer), the call holds a durable wait until Rails rings its doorbell
(`POST /v1/conversations/:id/wakes {key}`, the key Rails named in its
`waiting` answer), the re-check interval passes
(`limits.recheckMs`, default 60 s, so a lost ring costs at most that), or the
deadline passes; then it asks Rails again. The wait carries no decision.

## Messages and forks

A message is words or content blocks with up to four images (5 MB each, PNG,
JPEG, WebP or GIF); a model without image input is refused them
(`images_unsupported`). `POST /v1/conversations/:id/forks {requestId, at}`
copies a conversation up to entry `at` into a new one with the same scope and
definition, and an empty computer folder of its own. See
`docs/design/CONTRACT.md`.

## Models

Which models an agent may choose is Rails' allow-list (`config/pi_durable.yml`).
The sidecar runs every model in pi-ai's catalogue for each provider it holds a
credential for: a key (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), or a
subscription signed in from Rails' owner console through
`/v1/subscriptions/:provider` (`SUBSCRIPTION_VAULT_KEY` seals both):

- Claude: `CLAUDE_SUBSCRIPTION_FILE` (`claude-subscription.mjs`), never with
  `ANTHROPIC_API_KEY`.
- ChatGPT: `CHATGPT_SUBSCRIPTION_FILE` (`chatgpt-subscription.mjs`, provider
  `openai-codex`, beside `openai`). The owner pastes back the
  `localhost:1455` address its sign-in ends on (`openai-codex-oauth.mjs`).

`GET /v1/models` lists them with pi-ai's facts (name, thinking levels, images,
context window) for Rails' agent settings. A definition may name any thinking
level; the conversation runs at the nearest one its model supports.
`AGENT_MODEL_MODE=local` adds `local/stand-in` (`local-model.mjs`): a
scripted stand-in that streams replies and maps a few plain commands to tools,
costs nothing and calls no one. With no provider the sidecar is not ready
(`provider_credential_missing`). An agent's model is used or the run fails; none
is a fallback.

## Pushes to Rails

While a conversation runs, the sidecar POSTs `/agent/frames` (`{ conversationId,
seq, busy, tail, thinking, tools, failure }`, the whole live reply text and the
last 4 KB each running tool has printed, about every 100 ms; `seq` only grows,
across runs and restarts; the last frame adds the conversation's `usage`) and
`/agent/syncs` (`{ conversationId }`) when entries commit; Rails then pulls
`GET /v1/conversations/:id/entries?after=<entryId>`. Both are best effort.

## Execution modes

| `AGENT_EXECUTION_MODE` | Tools | Use |
| --- | --- | --- |
| unset or `none` (default) | No local computer | Production |
| `trusted-local-single-tenant` | Offers a local computer: an agent whose definition asks for one gets the native coding tools in `<cwd>/conversations/<id>` | One trusted tenant on a local machine; the test fixtures |

An agent gets `read`, `write`, `edit` and `bash` only when its definition names a
computer the sidecar offers (`computers.mjs`). `SPRITES_TOKEN` with
`SPRITES_IMAGE` offers Sprites, reached through `sprites-bridge.mjs` and, inside
the Sprite, `sprite-relay.mjs` and the pi-env daemon; see `docs/agent.md`.

Any other value fails readiness with `invalid_execution_mode`.

`AGENT_SHELL_NETWORK=isolated` (or `shellNetwork` in the config file) runs every
tool shell command in a fresh unprivileged user and network namespace
(`unshare --user --map-current-user --net`). The shell then has no route off the
host, not even to host loopback. Readiness fails with
`shell_isolation_unavailable` when the kernel or container refuses user
namespaces. This covers tool shells only.

`shellTmpDir` (config file) sets the tool shell's `TMPDIR` and where truncated
tool output is spilled. Unset, both use the host temporary directory. The sidecar's own Node process keeps
the host network, which it needs for Rails and the model provider.

One sidecar serves every workspace. A working directory is not a sandbox:
in trusted mode, a shell can read other workspaces, the Durable store, its
ownership lock and the sidecar configuration. Use trusted mode only where every
user is the same trusted operator. No per-workspace isolated execution
environment ships with this template. The tool shell gets a minimal environment
(`PATH`, `LANG`, `HOME`, `TMPDIR`) and does not inherit sidecar, provider or Rails
secrets.

## Listening

The sidecar listens on `127.0.0.1:$PORT` (default 4397). Set `AGENT_SOCKET`
(or `socketPath` in the config file) to an absolute path to listen on a Unix
socket with mode 0600 instead, for a Rails container that shares the volume.
A leftover socket file is replaced only by a sidecar that is ready, and so
already owns the store; any other file at that path refuses to start.

## Readiness

`GET /up` returns `{ ready, reason }`. The reason is a fixed category. It never
includes a path, token, stack or raw error:

| Reason | Action |
| --- | --- |
| `store_already_owned` | Another sidecar holds the store. Stop it first. |
| `storage_unavailable` | The store cannot be created or locked, for example a read-only directory. |
| `store_recovery_failed` | A retained store exists but cannot be opened or recovered. Restore a snapshot. |
| `incompatible_definitions` | Retained work needs a task definition this build lacks. Deploy a compatible build. |
| `approved_model_unavailable` | A provider's key does not answer for its own models. No other model is used. |
| `provider_credential_missing` | No provider has a key or subscription, and `AGENT_MODEL_MODE` is not `local`. |
| `shell_isolation_unavailable`, `invalid_execution_mode` | Fix that setting. |
| `anthropic_credential_ambiguous`, `claude_subscription_invalid`, `chatgpt_subscription_invalid` | Give Claude one credential: a key or a subscription. A subscription needs an absolute file, a 64-hex vault key and an environment. |

Work that crashes the process repeatedly is ended after `limits.restartLimit`
(default 5) crashes in a row. Durable gives the cut-off tool call an error result (or
ends the run); the sidecar then refuses the run's next model request at the
Models seam, so the run stops without an answer. The conversation reports
`blocked` with failure reason `restart_limit`. It is not retried silently.

## Run policy

- **Turns, as in pi.** A turn has no time limit and no cap on its tool
  rounds: it runs until the model answers or the person stops it. A model
  request that sends nothing for `limits.requestIdleMs` (default 300000, pi's
  provider idle timeout; `AGENT_REQUEST_IDLE_MS`) is given up, `request_timeout`;
  a web search gets the same time. `limits.maxRequests` (default 300;
  `AGENT_MAX_REQUESTS`) is a safety stop for an agent
  stuck in a loop, `request_limit`; it counts from the newest message the
  conversation received, so a steer or a follow-up starts it again. Messages
  queued behind a run that fails stay queued, as pi keeps them, and go in with
  the next message.
- **Retries.** A retryable provider error (rate limit, overload, 5xx, timeout)
  is retried by Durable up to `limits.maxRetries` times (default 2; 0 disables),
  with exponential backoff from `limits.retryBaseDelayMs` (default 2000 ms,
  capped at 30 s). Each attempt passes the Models seam and reserves a request
  in `limits.maxRequests`. A model request a crash cut off counts as a failed
  attempt; with no retry left the run ends with reason `interrupted`. SDK
  retries inside one attempt stay off.
- **Compaction.** Durable's automatic compaction is on: block to summarise
  at `min(262144, contextWindow - 16384)` tokens, start in the background
  32768 tokens earlier, keep about 20000 recent tokens verbatim. The 262,144
  (`COMPACT_AT_TOKENS`; `AGENT_COMPACT_AT_TOKENS` or `compactAtTokens` in the
  config file override it) becomes a per-model `reserveTokens` override for
  every route with a larger window, computed at boot; `GET /v1/models` reports
  each model's `compactAt`. `compaction` in the config file overrides
  `enabled`, `reserveTokens`, `keepRecentTokens` or `backgroundTokens`.
  `POST /v1/conversations/:id/compactions` asks for one now. Summaries are
  model requests and count toward `maxRequests`. The snapshot still shows
  every entry, with each summary in place as role `summary`.
- **Progress persistence.** Streamed answers and tool output are stored within
  `limits.persistWithinMs` (default 100 ms; Durable's own default is 1000 ms),
  so a crash loses at most about that much streamed text.

## Not here

The sidecar runs no MCP client, no file-based skills and no
extension modules: an agent's instructions and tools live in Rails and arrive in
its definition. The one file it reads is the agent's notes file (`AGENTS.md` on
its computer, when the definition's computer says `notesFile`), appended to
the instructions when a run starts. Code mode is the one sandbox: Pi Durable's `codemode` tool
(QuickJS in a worker thread, at most 64 MB per script), offered to every
conversation; a script reaches only the conversation's own tools.

## Store ownership

`<store>.owner.sqlite` is held with `BEGIN EXCLUSIVE` before the Durable store
opens for writing. The kernel releases it when the owner exits, including on
`SIGKILL`. There is no lease, PID check or lock deletion. A second process gets
`store_already_owned` and reports not ready.

The lock relies on advisory locks on a local filesystem. A store on a network or
shared volume mounted by more than one host is unsupported. When replacing a
deployment, stop the old sidecar before starting the new one.

## Snapshot and restore

```sh
node store.mjs snapshot <store.sqlite> <snapshot.sqlite>
node store.mjs restore  <snapshot.sqlite> <fresh-store.sqlite>
```

- Both take the same ownership lock, so they refuse while a sidecar runs.
- Neither loads a model provider, harness or extension.
- A snapshot is a consistent `VACUUM INTO` copy that includes committed WAL
  data. It passes `PRAGMA integrity_check` and is published by rename. A
  `<snapshot>.manifest.json` with its SHA-256 is written last. A snapshot without
  a manifest is incomplete.
- Restore writes only to a fresh path. It checks the digest and SQLite
  integrity before the store appears.
- The command prints a JSON category. It exits 0 on success, 1 on refusal and
  64 on a usage error.

## Evidence notes

- **A13/A22, request bound:** each provider request, including one re-issued
  after recovery, reserves a slot in the persisted request bound. The slot is
  reserved immediately before dispatch, at the `Models` seam. A recovered
  conversation can therefore use fewer fresh requests than `maxRequests`. This
  is deliberate: the bound caps requests actually sent, not distinct turns.
  Hook exceptions are not used as hard limits.
- **A15/A21, cancellation:** cancellation records the live task tree first. The
  tree is the conversation, the conversations its tasks own, and all their tasks,
  background ones included. The sidecar then aborts with
  `Conversation.abort({ background: true })` and joins every recorded task. A
  retry re-settles only the recorded tasks. Reopening the store re-aborts any
  recorded task that is still live.
- **Snapshot DTO:** `GET /v1/conversations/:id` returns only
  `{ id, entries, pendingInputs, status, failure, usage }`. `entries` is the
  whole history, paged from the store (Rails reads the page through
  `GET .../entries` instead and uses this only for `status` and `usage` on a page load).
  `failure` is `null` or `{ reason }`, why the newest
  run ended without an answer (`model_error`, `interrupted`, `restart_limit`,
  `aborted`, `turn_limit`, ...); its detail text never leaves. Task identities, scope
  bindings and raw Durable state are not exposed. `pendingInputs` lists the
  calls waiting for a person (`{ id, kind: 'person', expiresAt }`); the question
  or approval itself is Rails' record. `status` is one of `idle`, `running`,
  `waiting`, `done`, `error`, `cancelled` and `blocked`.
- **Usage:** `usage` sums the runtime's `pi.usage` rows once each: `input`,
  `output`, `cacheRead`, `cacheWrite`, `totalTokens`. `cost` is
  `{ estimatedTotal: null, basis: 'price_unavailable' }` unless the model route
  has catalogue prices. Even then it is an estimate, not a provider bill. The
  last frame of a run carries the same totals. Each assistant entry in
  `GET .../entries` carries its own reply's `usage`, with `cost` a plain number
  (0 when unpriced).
- **Images:** in trusted mode, reading a file named as an image (`.png`,
  `.jpg`, `.bmp` and similar) that is not a decodable image fails with an error.
  It is never handed to the model as text.
