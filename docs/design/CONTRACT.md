# The Rails ↔ sidecar service contract (v1)

Two services, one contract. Rails is the application: people, agents, tools,
approvals and every domain record. The sidecar (Node, Pi Durable) is
infrastructure: it runs the model loop, keeps each conversation durable across
crashes, and runs each conversation's computer. It holds no business rules. This file is
the whole wire contract; `docs/agent.md` is the operator's runbook.

## Shape

```text
browser ──CSRF──▶ Rails web ──SIDECAR_TOKEN──▶ sidecar      (commands, reads)
                  Rails web ◀──RAILS_TOKEN──── sidecar      (tool calls, frames, pings)
                  Rails job ──SIDECAR_TOKEN──▶ sidecar      (doorbells, pulls)
```

- Three containers on one host and one volume: `web` (Falcon), `job` (Solid
  Queue), `agent` (the sidecar). Rails reaches the sidecar over a Unix socket on
  the shared volume; the sidecar reaches Rails over HTTP at the web role's
  network alias. Nothing is published to the internet but `web`.
- Two bearer tokens, one per direction, distinct and at least 16 characters.
  Either side refuses a request without the right one.
- JSON both ways. Errors are a status and a fixed category, `{error:
  "model_unavailable"}`; no message, path or stack leaves the sidecar.
- Every call names its scope: `actorId` (the person) and `workspaceId` (the
  agent), in the body or, for reads, the query. An id is a lookup key, never
  authority. The sidecar asks Rails about the pair (`POST /agent/accesses`)
  when a conversation is created and before every tool call and model request,
  so access Rails revokes stops a run; it does not ask about Rails' own
  commands, which the token already vouches for.

## Rails → sidecar

| Call | Body | Answer | Repeatable |
|---|---|---|---|
| `POST /v1/conversations` | `{requestId}` | `201 {id}` | yes: same `requestId`, same `id` |
| `POST /v1/conversations/:id/submissions` | `{requestId, content, whenBusy, definition}`; `content` a string or blocks (below) | `202 {id, status}` | yes: same `requestId` and content; changed content is `409` |
| `POST /v1/conversations/:id/forks` | `{requestId, at, into?}` | `201 {id}` | yes: same `requestId`, same `id`; another `at` or `into` is `409` |
| `POST /v1/conversations/:id/wakes` | `{key}` | `200 {rung: true}` | yes; it carries no decision |
| `POST /v1/conversations/:id/cancellations` | `{requestId}` | `200 {cancelled: true}` | yes |
| `PATCH /v1/conversations/:id/queued/:queuedId` | `{whenBusy}`: `steer` or `followUp` | `200 {changed}`: false once the agent has taken it in | yes |
| `DELETE /v1/conversations/:id/queued/:queuedId` | | `200 {withdrawn}`: false once the agent has taken it in | yes |
| `POST /v1/conversations/:id/compactions` | `{requestId, instructions?}` | `202 {id}` | yes: same `requestId`, same `id`; other `instructions` are `409` |
| `GET /v1/conversations/:id/entries?after=&limit=` | | `200 {entries, cursor, more}` | yes; a read |
| `GET /v1/conversations/:id` | | `200 {status, pendingInputs, failure, usage, compaction, compactionFailed, notesFile, queued, …}` | yes; a read, on a page load only |
| `GET /v1/conversations/:id/export?title=` | | `200`, `application/jsonl`: pi's session file | yes; a read |
| `GET /v1/conversations/:id/screen?computer=` | a websocket upgrade | `101`, then the conversation's screen as VNC over the websocket | yes; each opens its own |
| `GET /v1/conversations/:id/computer?computer=` | | `200 {waking}`: `"cold"` or `null` | yes; a read that wakes nothing |
| `POST /v1/conversations/:id/connectors/:name/rpc` | `{computer, entry: {command, args, env, cwd}, message}` | `200 {message}`: the server's JSON-RPC reply | no; MCP has no idempotency key |

`GET /v1/models` answers `200 {models: [{id, name, thinkingLevels, images,
contextWindow, compactAt}]}`: every model the sidecar can run now (pi-ai's catalogue for
each provider it holds a credential for), with pi-ai's facts about it, and
`compactAt`, the context size in tokens at which the sidecar summarises a
conversation on it (null when it does not). Rails
offers the models on its own allow-list that appear here, each with its own
`thinkingLevels`, and caches the answer for ten minutes; without an answer it
offers its whole list with every level. Like the console's calls below it
names no scope.

The owner console uses four more calls per subscription, about the app rather
than a person's agent, so without `actorId` or `workspaceId`. `:provider` is
`anthropic` (the Claude subscription) or `openai-codex` (the ChatGPT
subscription); one the sidecar has no place for answers `404
subscription_not_configured`. Each change names the `version` it saw (`412
subscription_changed` otherwise); the sign-in link is in `start`'s answer
only. The grant itself never leaves the sidecar.

| Call | Body | Answer |
|---|---|---|
| `GET /v1/subscriptions/:provider` | | `200 {connected, version, expiresAt, reconnectRequired, pending}` |
| `POST /v1/subscriptions/:provider/start` | `{version}` | `200 {…, pending: {id}, authorizationUrl}` |
| `POST /v1/subscriptions/:provider/finish` | `{version, id, code}` | `200 {connected: true, …}`; `400` wrong or expired; `503` unconfirmed, sign in again |
| `POST /v1/subscriptions/:provider/disconnect` | `{version}` | `200 {connected: false, providerRevoked: false}` |

`code` is what the owner pasted: Claude's `code#state`, or for ChatGPT the
`http://localhost:1455/auth/callback?code=…&state=…` address its sign-in ends
on (its query string, or `code#state`, also do). The sidecar checks the state.

Beside the subscriptions, the owner may paste an Anthropic API key:
`anthropic-api`, a provider of its own, so an agent on `anthropic-api/<model>`
is billed per token to the key and one on `anthropic/<model>` uses the
subscription; neither ever stands in for the other. Rails passes the key
straight through and keeps nothing. The sidecar refuses a key that is not
`sk-ant-…` (a subscription's own `sk-ant-oat`/`sk-ant-ort` tokens included),
is not printable ASCII without spaces, or is over 512 characters, then asks
Anthropic's free `GET /v1/models` with it: refused (401/403) is `422
invalid_api_key`, any other answer or none is `503 api_key_unverified`, and
neither is kept. A kept key is sealed in the subscriptions' file under its
own namespace. Only its last four characters ever come back, as `hint`. The
same `404 subscription_not_configured` and `412 subscription_changed` apply.

| Call | Body | Answer |
|---|---|---|
| `GET /v1/subscriptions/anthropic-api` | | `200 {configured, connected, version, hint}` |
| `PUT /v1/subscriptions/anthropic-api/key` | `{version, key}` | `200 {connected: true, hint, …}`; `422 invalid_api_key`; `503 api_key_unverified` |
| `DELETE /v1/subscriptions/anthropic-api/key` | `{version}` | `200 {connected: false, hint: null, …}` |

The `anthropic-api` routes are in `GET /v1/models` whenever the sidecar has a
subscription file, before a key is saved, like a subscription's before its
sign-in; a run on one without a key stops with `credential_missing`.

**A summary** (compaction) shrinks what the model sees: earlier messages are
summarised and the model works from the summary and the recent messages. It
appears as an entry with role `summary`; the messages it replaced stay in
`entries`. The sidecar summarises on its own at about 262,144 tokens
(`min(262144, contextWindow − 16384)`, overridable with
`AGENT_COMPACT_AT_TOKENS`), starting in the background 32,768 tokens earlier.
`compactions` asks for one now (`/compact`): `instructions`, at most 4,096
characters (`422 invalid_instructions` otherwise), say what it should keep.
The conversation goes on while it is made; it is placed when the conversation
is idle or at its next turn boundary.

**The export** is the conversation's whole history as pi's session file
(format v3, one JSON object per line), so `pi --session <file>` opens it.
It is built from the sidecar's store, not Rails' messages: a header with
`cwd` `"."` (never a host path), a `session_info` named `title` (Rails sends the conversation's), a system
message with the agent's instructions and a `model_change`, then each message as pi-ai's message object, with
its usage and its pictures inline, in one linear `parentId` chain. A summary
is a `compaction` entry (`summary`, `firstKeptEntryId`, `tokensBefore`, the
instructions as its `systemMessage`). A fork's file includes its parent's
history and names no `parentSession`. Thinking signatures and redacted
thinking are left out. The body streams; a failure after it has begun cuts the
connection, so a reader sees the file is incomplete.

**A fork** is a new conversation that starts as a copy of `:id` up to and
including entry `at` (an `entryId` from `entries`; `422 invalid_entry` if it is
not in that conversation's history) and goes on on its own. It keeps the
scope and the agent's definition, so its tools work from its first message, and
it is a conversation of its own: its computer is a fresh, empty one. Its `entries` from no cursor include the
copied history under the parent's entry ids.

With `into: {workspaceId, cwd}` (`422 invalid_into` otherwise) the fork is
another agent's thread, for "New agent from here": the same `actorId`, that
agent's workspace and absolute folder, as Rails mints them for it. It does
not keep the parent's definition; it runs as a new conversation does until
Rails sends the new agent's with its first message. From then on it answers
to the new agent's scope, not the parent's.

**The screen** is the conversation's Sprite desktop (Chromium on a virtual
display), for the person to watch and type into while the agent works.
`computer` is the agent's Sprite prefix (as in the definition), so the screen
opens before the conversation's first message too; the call names its scope like a
read. The sidecar checks the bearer and the scope, wakes the Sprite (up to two
minutes; `429 computers_busy` at the awake cap, `503 computer_unavailable`
when it cannot), then passes the request on to the guest's websockify as `GET
/websockify` without the bearer, and pipes bytes both ways without reading
them. While the socket is open the Sprite is kept awake. Refusals are plain
HTTP answers with the usual `{error}` body: `401`, `404 not_found` (another
scope), `422 invalid_computer`, `422 computer_unavailable` (no Sprites here).
Rails checks the person, the computer (a Sprite that is on) and the page's
Origin before it calls.

**`computer`** answers `{waking: "cold"}` when the conversation's Sprite has its disk
in cold storage (the platform's row says `state: "cold"`), so the next wake
takes up to a minute rather than seconds, and `{waking: null}` otherwise,
including a Sprite that does not exist yet. It is a lookup: nothing is
created or started. It takes the screen's query (`computer`, the scope) and
refuses as the screen does. Rails asks when it renders the screen's page and
shows "Waking up, this can take a minute" when `waking` is set, else
"Waking the computer…"; if the sidecar cannot answer, the usual words. The
run does not carry it: a message or tool call that wakes a cold computer shows
"Working…" as before.

**A command connector** is pi's `command` MCP server entry, run on the
conversation's own computer (`docs/connectors.md`). Rails is the MCP client and sends
one JSON-RPC request per call: `message` is `{jsonrpc: "2.0", id, method,
params}`, `entry` the connector's `command`, `args`, `env` (literal values)
and `cwd`, and `computer` the agent's computer as in the definition. `:name` is
the connector's name. The sidecar keeps one process per conversation and
name, on that conversation's computer: in its Sprite, started by the relay
(`AGENT-COMMAND <secret>`, then the entry as one JSON line, then the
command's stdin and stdout), or in its local folder. It makes the MCP
handshake when it starts one, answers the server's `ping`, refuses the
server's other requests, and passes `message` on under an id of its own. The
answer is the reply under Rails' `id`. It starts the process again when it
has died or the entry or computer differs (a digest of them), and stops it
after 10 minutes without a message. A failure of the command (it exited, did
not answer within 30 seconds, refused the handshake) is a JSON-RPC error in
`message`, `{code: -32000, message}`, with at most 500 characters of the
command's stderr. Refusals of the call itself are plain HTTP answers: `401`,
`404 not_found` (another scope), `422 invalid_computer`, `422
computer_unavailable` (that kind of computer is not offered here), `422
invalid_connector`, `422 invalid_message`, `429 computers_busy`, `503
computer_unavailable` (the Sprite could not wake). Waking a Sprite may take
two minutes, so Rails waits up to 180 seconds. Rails checks the person, the
conversation and that its agent's computer is on before it calls.

**A message's content** is the person's words as a string, or content blocks:
`[{type: "text", text}, {type: "image", data, mimeType}]`, `data` base64. At
most 4 images, each at most 5 MB, `image/png`, `image/jpeg`, `image/webp` or
`image/gif`; words at most 64 KB. A message may be images alone, never nothing.
The sidecar refuses a shape or limit it does not accept (`422
invalid_content`, `invalid_images`) and images to a model without image input
(`422 images_unsupported`). A submission body may be up to 32 MB; any other
body, 1 MB. The `requestId` digest covers the blocks, images included. Rails
keeps no copy of what it sent: the person's message comes back as an entry
with its `images`, which Rails attaches like a tool's screenshot.

**The definition** is the agent as Rails knows it now, sent with every message:

```json
{ "instructions": "…", "model": "anthropic/claude-sonnet-5-5", "thinkingLevel": "medium",
  "tools": [{ "name": "remember_note", "description": "…", "parameters": { "type": "object", … } }],
  "capabilities": ["codemode", "subagents", "web_search"],
  "computer": null | { "provider": "local", "notesFile": true } | { "provider": "sprites", "name": "…", "notesFile": true },
  "digest": "<sha256 of the canonical JSON of everything above>" }
```

`capabilities` names which of the sidecar's built-in abilities the agent has:
`codemode`, `subagents`, `web_search`, each at most once (`422
invalid_capabilities` otherwise). Rails' allow-list is
`config/pi_durable.yml`; the sidecar installs only the ones named. A
definition without the key has none.

**A computer per conversation.** Each conversation gets its own
computer, made the first time it is used; the definition's `computer` is the
agent's template for them. A local computer is the folder `<agent's cwd>/<id>`
(`cwd` from `accesses`). A Sprite's `name` is a prefix: the sidecar names the
conversation's Sprite `<name>-c<id>`, `id` the sidecar's conversation id, and
refuses a prefix that leaves no valid Sprite name (at most 63 characters of
`a-z`, `0-9` and `-`). The agent works in the computer's home folder. A
helper uses the computer of the conversation it works for.

`notesFile`, a boolean (absent means false), says whether the sidecar reads
the conversation's notes file, `AGENTS.md` in its computer's home folder (each conversation
has its own), when a message starts a run. Its contents follow
the instructions under `# Notes file (AGENTS.md)`; a file over 32 KB is not
read and the agent is told so. A changed file reconfigures the conversation
from that run, as a new digest does; within a run it is not read again.

`thinkingLevel` is one of `off`, `minimal`, `low`, `medium`, `high`, `xhigh`,
`max`; the conversation runs at the nearest level its model supports (pi-ai's
`clampThinkingLevel`), so a level never refuses a message.

The sidecar installs each digest once and reconfigures the conversation when
the digest changes, so an edit to an agent applies from its next message. It
refuses a model, computer or tool shape it cannot honour (`422`
`model_unavailable`, `computer_unavailable`, `invalid_tools`, …), and Rails
shows the person why. Tool names may not shadow the sidecar's own (`read`,
`write`, `edit`, `bash`, `visit_website`, `desktop`, `codemode`, `subagent`,
`web_search`, `skill`).

**Entries** are the committed transcript, oldest first, after a cursor:
`{id, entryId, role: user|assistant|toolResult|summary, content, thinking?,
toolCalls?: [{id, name, arguments}], toolName?, toolCallId?, isError?, images?:
[{mimeType, data}], usage?}`. A page stops at about 3 MB, but always holds one
entry (a person's message with four pictures is about 27 MB); `more` says to
ask again.
An assistant entry's `usage` is what that reply used: `{input, output,
cacheRead, cacheWrite, totalTokens, cost}`, with `cost` in dollars at the model
catalogue's API prices (0 when the model has none). It is an estimate, not a
bill; a subscription is not billed per token.
A call's `arguments` are what the person sees go in (a command, a URL, a
script); a sidecar tool's result is shown in its call's place.

**Code mode.** An agent with the `codemode` capability has the sidecar's `codemode` tool: the model
writes one JavaScript script (a QuickJS sandbox, no file system or network of
its own) that calls the conversation's tools as `tools.<name>(args)`, in loops
or with `Promise.all`. Each call a script makes reaches Rails as an ordinary
`invocations` call, so the ledger, approvals and questions apply unchanged. Its
`callId` is `<script's callId>/c<n>`: Rails lists it inside the script's line.

**Helpers.** An agent with the `subagents` capability has the sidecar's
`subagent` tool, `{task, context?}`: a helper conversation, owned by the call,
runs the task with the agent's model, instructions, tools and computer,
but no helpers of its own, and its final answer is the call's result. Rails
never learns the helper's conversation: its calls to the agent's tools reach
`invocations` with the root `conversationId` and `callId`
`<helper's callId>/<its own callId>` (a script the helper runs nests once more,
`<helper>/<script>/c<n>`), so the ledger, approvals and the root's `wakes`
work unchanged. Its model requests count against the root's run bounds, and
its spend is in the root's `usage`.

**The conversation's screen as tools.** On a Sprite, `visit_website` opens a tab in
the screen's Chromium over CDP, so logins made there apply and the person sees
the page; where that browser is not running, and on a local computer,
headless Chromium loads it. A conversation whose computer is a Sprite also has the
sidecar's `desktop` tool (`{action: screenshot|click|type|key|scroll|drag|wait,
…}`, the desktop control server's actions), each answered with a
screenshot. A helper never gets `desktop`: only the agent drives its screen.

**Web search.** An agent with the `web_search` capability has the sidecar's
`web_search` tool, `{query}`. It uses the provider of the conversation's
model, with the credential the chat uses (never one of Rails'): on Claude,
Anthropic's own search on `claude-haiku-5-5` (as Claude Code on the
subscription, as plain API traffic with `x-api-key` on `anthropic-api`); on
the ChatGPT subscription, Codex's. Other models, or a subscription not signed in, get a plain error
result. The result is Markdown: the answer, then `Sources:` with up to eight
links. Each search counts as a request of the run, and its spend is in
`usage`.

A nested call's parent is everything before the last `/`. The page lists
every nested call inside the line of the outermost call, the one the agent's
reply made.

## Sidecar → Rails

| Call | Body | Answer |
|---|---|---|
| `POST /agent/accesses` | `{actorId, workspaceId}` | `{allowed, actorId, workspaceId, cwd}` |
| `POST /agent/invocations` | `{actorId, workspaceId, conversationId, taskId, callId, tool, arguments, digest}` | `{status: "done", result, isError}` or `{status: "waiting", key, expiresAt}`; `409` for a changed replay |
| `POST /agent/frames` | `{actorId, workspaceId, conversationId, seq, busy, tail, thinking, tools, failure, compaction, compactionFailed, queued?, usage?, notesFile?}` | `204` |
| `POST /agent/syncs` | `{actorId, workspaceId, conversationId}` | `204` |

`waiting` names the wait: Rails chooses `key` and rings the doorbell with the
same key, so neither side builds the other's names. A wait may be for a person
(an approval or a question, with `expiresAt`) or for an outside call Rails is
making in a job (no `expiresAt`): an MCP server, or a command connector
waking a Sprite, can take minutes, longer than the sidecar waits for an
answer. The sidecar holds both the same way and reports either as `waiting`;
Rails tells them apart.

`failure` (in a frame and in `GET /v1/conversations/:id`) is a fixed reason
category, never provider text: Pi Durable's run-failure reason, except that a
model error for a usage limit (HTTP 429, a subscription's limit) is
`rate_limited`, so Rails can tell the person to wait or switch subscription,
and one for a model whose credential is missing (a subscription signed out,
no API key saved) is `credential_missing`, so Rails can say where to set it,
and one for a request that waited for a summary that failed is
`compaction_failed`, so Rails can say to ask for one again. A run whose
Sprite could not wake because the platform's awake cap is reached (`429
scope_capacity_exceeded` from create, start or wake) is `computers_busy`:
nothing is queued and no other conversation is put to sleep, so the person tries
again shortly. A run the sidecar's own guards ended is `request_limit` (the
safety stop on model requests, which counts from the newest message) or
`request_timeout` (a model request that sent nothing for five minutes);
neither is a time limit on the turn, which has none.

`compaction` (in a frame and in `GET /v1/conversations/:id`) is `{trigger}`
while a summary is being made, `trigger` `manual` (asked for), `threshold` or
`overflow` (on its own), else null. `compactionFailed` is `{trigger}` of the
newest summary that failed, until one succeeds, else null. The provider's
error never leaves the sidecar. A summary asked for while the conversation is
idle sends frames with `busy: false` until it is placed.

`queued` (in `GET /v1/conversations/:id`, and in a frame when it changed and
in every whole frame) lists the messages waiting for the agent to take them
in, oldest first: `[{id, mode, text, pictures}]`, `mode` `steer` (read after
the agent's current step) or `followUp` (read when it finishes). The
`PATCH` and `DELETE` above change or withdraw one by that `id`; Rails offers
them only for the person's own words. Taken in, a message leaves the list and
arrives as an entry.

Each line in a frame's `tools` is `{callId, name, status, output, arguments?,
count?}`: a helper's line carries `count`, how many calls it has made, and the
calls it made follow it, named `<helper call>/<its call>`, each with its
`arguments` and a status of `running`, `done` or `failed`. A helper's result
entry carries them all, settled, as `calls` (the newest 64, each output cut
to its last kilobyte) with `callCount`, so the page keeps them under its line.

`notesFile` (in the last frame and in `GET /v1/conversations/:id`) is
`{bytes}`, the size of the notes file the conversation runs with (over 32 KB:
it was too large to read), or null when none is read.

## Delivery: what each message promises

- **Commands are idempotent by `requestId`.** Rails may retry any command after
  a timeout; the sidecar answers a repeat with the first outcome. Rails never
  retries a command whose content changed under the same id.
- **A tool call runs once.** The sidecar may send the same call again after a
  crash (`taskId:callId` names it; `digest` covers it). Rails records it once in
  the `Invocation` ledger and answers every repeat from the record. A tool with
  an outside effect passes `taskId:callId` on as the provider's idempotency key.
- **A call can wait for a person, or a slow outside call, without holding a
  request open.** Rails answers `waiting`; the sidecar holds a durable wait.
  When the person decides, or the job making the outside call records its
  result, Rails rings the doorbell (`wakes`) after its transaction commits,
  and the sidecar sends the call again and gets the outcome. The sidecar also re-sends
  every 60 seconds, so a lost doorbell only delays.
- **Frames replace, never append.** Each frame carries the whole live reply so
  far (`tail`, `thinking`), about ten a second while generating. `seq` only
  grows, across runs and restarts, so the page drops an older frame that arrives
  late. A lost frame is healed by the next. The last frame (`busy: false`)
  carries no reply, because the reply is a committed entry by then; it has no
  next, so the sidecar retries it, and a page load takes the status from
  `GET /v1/conversations/:id` in case it never arrived.
- **Frames carry running tools' output.** `tools` lists the calls running
  now, `[{callId, name, status: pending|running|done, output}]`, with the last
  4 KB of what each has printed (a shell command's output as it runs). A
  model-issued call leaves the list once it is done, since its result is an
  entry by then; a code mode script's own calls (`callId` `<script's
  callId>/c<n>`) stay until the script settles, since their results never
  become entries. A helper's calls are listed too, under its call
  (`<helper's callId>/<callId>`), until the helper answers. A change in
  output alone sends a frame. Rails shows it and
  never stores it: the committed result replaces it. The last frame's `tools`
  is empty, and it adds `usage`: the conversation's totals as
  `GET /v1/conversations/:id` reports them (they also count compaction and
  tools), `{input, output, cacheRead, cacheWrite, totalTokens, cost:
  {estimatedTotal, basis}}`, `estimatedTotal` null when the model has no
  prices.
- **Pings say "pull", not "here it is".** On `syncs` Rails pulls `entries`
  after its own cursor into `messages`, its rebuildable copy. Each page load
  pulls too. The cursor, not the ping, decides what is new; each entry is
  recorded once, by its id. `Conversation#resync!` rebuilds the copy.
- **A committed entry is on the page before the live tail clears.** Rails
  pulls inside the `syncs` callback and the last frame's, not in a job: the job
  worker polls once a second, and a reply cleared from the tail before its
  message arrived blinked out for that long. The sidecar awaits each ping
  before its next frame, so the order holds. A pull that fails falls back to a
  job. This is the one place Rails calls the sidecar from a callback; the
  sidecar serves the read while it waits, and holds no lock across the ping.
- **A message to a busy conversation** says what to do with it: `steer`
  (default for Enter in the page) joins the running turn after its current
  tool calls; `followUp` (Queue) waits for the run to finish. Until the run
  takes it, it is listed in `queued`, which retires the page's echo; taken
  in, it is committed as an entry.
- **No HTTP inside a database transaction**, on either side of the wire.

## Who owns what

| Rails | Sidecar |
|---|---|
| People, agents, revisions, instructions, model choice | The model loop, retries, compaction, request bounds |
| Tools: the schema, the code, approvals and answers | Forwarding each tool call; the durable wait |
| The `Invocation` ledger (exactly-once) | The durable store (conversations, tasks), canonical |
| `messages`: a rebuildable copy for the page | Entries and the cursor |
| The `Computer` record: whether and which | Running the computer (a local folder or a Sprite), its file, shell and browser tools |
| Connectors: the entry, the tool list, sign-in, approvals | A command connector's process on the conversation's computer |

## Not MCP, on purpose

MCP between the two services would carry the call but none of the hard parts:
exactly-once, the hours-long wait and per-message tool lists would all stay, now
inside JSON-RPC, and the sidecar's MCP client (pi-mcp 1.5.0) speaks a protocol
version without a "come back later" result. Our `waiting` is the same idea as MCP 2026-07-28's
`input_required`, so a later move is mechanical. If outside clients ever need
an agent's tools, Rails adds a separate `/mcp` endpoint with the official `mcp`
gem over the same `Tool` classes and ledger.

## Changing this contract

One version, `v1`, in the path. A change both sides must understand lands in
one commit with both sides and their tests; the sidecar's suite runs a Rails
stand-in (`agent/test/rails-stand-in.mjs`) and the Rails suite stubs the
sidecar, and both check the shared digest vector.
