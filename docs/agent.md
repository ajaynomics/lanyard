# Agent sidecar (optional Pi Durable)

This app was generated with `PI_DURABLE=1`. It adds a Node sidecar running the
published `@earendil-works/pi-durable` runtime (pinned in
`agent/package-lock.json`) beside Falcon and Solid Queue. Rails stays the
application: people, agents, tools, approvals, the invocation ledger and every
domain record. The sidecar is generic infrastructure: it owns the durable
conversation and task state in its own SQLite store, runs the model, and
forwards every tool call to Rails.

```text
browser --CSRF--> Rails --SIDECAR_TOKEN--> sidecar (loopback or Unix socket, /v1/...)
                  Rails <--RAILS_TOKEN---- sidecar (/agent/accesses, /agent/invocations,
                                                    /agent/frames, /agent/syncs,
                                                    /agent/sign_ins)
```

## What Rails supplies

- **Access.** `Agent::Access.for(agent)` names the person (`actorId`) and the
  agent (`workspaceId`) on every call. `POST /agent/accesses` answers for
  exactly that pair or refuses; an id in a URL or a sidecar request is a
  lookup key, never authority.
- **The definition.** Every submission carries `Agent#definition`:
  instructions, model, thinking level and each enabled tool's name,
  description and JSON Schema, plus a SHA-256 digest of all of it. The
  sidecar installs it as extension `bot.<digest>` (the name predates the rename
  and is kept, since it is stored in the sidecar), so an edit to an agent applies
  from the next message, and reinstalls the definitions still in use at boot.
- **Tools.** Each tool is a Ruby class in `Tool::Catalog`. The sidecar's tool
  is a forwarder: it posts the call to `/agent/invocations` and returns what
  Rails answers. Rails checks the arguments against the same schema, records
  the call in the `Invocation` ledger and runs it, or asks the person first.
  A person's connectors (MCP servers, `docs/connectors.md`) add tools named
  `mcp__<server>__<tool>`: Rails signs in, lists them (`McpServerRefreshJob`)
  and calls the server itself, so the sidecar sees one more forwarded tool
  and nothing else.

## The prompt cache

The sidecar sends what pi sends, so the provider's prompt cache holds as it
does in pi: the same session id on every request of a thread, the default
five-minute retention, and every change to the agent (its instructions, its
notes file, its tools, a connector's) written by pi-durable as a later
system message, which Claude 5 takes mid-conversation without touching the
cached prefix. Nothing app-owned is in the prompt per request: the time is a
tool (`current_time`), the notes file is read once per run, and tools are
declared in a fixed order.

The date is told as pi tells it (pi 0.80.7): never in the system prompt, but
at the end of the newest message, once a day in the agent's zone and again
after a summary (`Conversation#date_note`, `conversations.dated_on`):
"Current date: 2026-11-10 (Tuesday), in UTC. For the time, use current_time."
It is new words at the end, so the cached prefix holds; no view shows it.
Each message from someone else (Concourse, Campfire, mail, texts, a routine)
says when it was written, from the channel's own time, or when it arrived:
"Sent 2026-11-10 12:01 PST (20:01Z)" (`Conversation.received`).

One exception, `agent/current-instructions.mjs`: when a thread's agent has a
new identity ("New agent from here"), its requests are sent with one leading
prompt, the new name first, which spends that thread's cache once and again
on each later change until compaction. A model switch spends it too, as it
does in pi: the cache is per model.

## Processes

| Process | Command | Notes |
|---|---|---|
| web | `bin/falcon` | unchanged |
| jobs | `bin/jobs` | unchanged; Solid Queue stays its own role |
| agent | `bin/agent` (production: `bin/agent-container`) | the sidecar; loopback `AGENT_PORT` (4397); exactly one per store |

`bin/dev` (`Procfile.dev`) starts web and agent in development, and `bin/jobs`
runs in a second terminal. In production each is its own Kamal role (below). `bin/agent` starts Node with
a clean environment: only the two transport tokens, its port, store path,
Rails URL, the provider keys (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), the
subscriptions' files (`CLAUDE_SUBSCRIPTION_FILE`, `CHATGPT_SUBSCRIPTION_FILE`)
and their vault key, the
Sprites settings (`SPRITES_TOKEN`, `SPRITES_IMAGE`, `SPRITES_URL`, `SPRITES_IDLE_MS`),
`AGENT_MODEL_MODE`, `AGENT_EXECUTION_MODE`, `AGENT_COMPACT_AT_TOKENS`,
`AGENT_SHELL_NETWORK` and `AGENT_CONFIG` reach it, never the app's other
secrets.

### Tool calls and the package patch

A model's tool calls in one message run at once, as pi's do, and their
results reach the model in the order it made the calls. A tool that shares
state declares `executionMode: 'sequential'` (`visit_website` and `desktop`
share the screen), and one such call makes its round run one call at a time.
pi's own `edit` and `write` queue changes to one file.

pi-durable 1.5.0 can leave such a round's turn waiting for ever, or its
parent completing (earendil-works/pi#11892; a bot closed it as a first
contribution, and it may be reopened). `agent/patches.mjs` applies the
reporter's proposed fix, kept as small as it can go upstream as-is, to the
installed package after every `npm ci` (`bin/agent`, `bin/agent-test`, the
Dockerfile); its comment says why it holds. A
pi-durable upgrade that moves that code fails the build;
`agent/test/tool-calls.test.mjs` runs 400 shuffled parallel rounds and 400
rounds of tools that start a helper, and fails on one hang (unpatched, both
hang). Review the patch against the new version, and drop it once upstream
fixes the bug.

Under it, Rails has a safety net: the sidecar reports `stalled` when a run's
tasks, a helper's included, are there and none runs or sleeps, and
`ConversationRecoveryJob` (every minute) ends a run stalled for two minutes
(`Conversation::STALL_LIMIT`), as Stop would, saying why.

### Computers

Each conversation has its own computer: its file, shell and browser tools
(`read`, `write`, `edit`, `bash`, `visit_website`, and on a Sprite `desktop`)
run there. Rails' `Computer` record is the agent's template: whether its
conversations have one, which kind (`config/pi_durable.yml` lists the
kinds an environment may use) and whether the notes file is read. It reaches
the sidecar in the agent's definition, so turning it on or off applies from the
next message. The sidecar refuses a kind it cannot offer
(`computer_unavailable`). There is no table of computers: each one's name is
derived, and it is made the first time the conversation uses it. An agent made
with "New agent from here" is a new agent, so it starts with a fresh, empty computer. Archiving leaves the
computer asleep; nothing deletes it. Helpers share their conversation's computer.

The conversation's notes file is `AGENTS.md` in its computer's home folder; each
conversation has its own (agent-wide memory stays in Rails' notes). The owner may drop
one there and the agent may keep its own notes in it. Unless the computer
settings turn it off, the sidecar reads it, through the computer (on a
Sprite, the Sprite reads it), when a message starts a run, and appends it to
the agent's instructions under `# Notes file (AGENTS.md)`. A file over 32 KB is
not read and the agent is told so; a symbolic link is not followed. A
computer that does not answer within 5 seconds (a Sprite waking) leaves the
conversation with the notes it last read.

- **`local`** is the directory `<agent folder>/<conversation id>` under the
  agent's working directory on this machine (`storage/agent/computers/bot-<id>`:
  the folder's name predates the rename and is kept), offered only with
  `AGENT_EXECUTION_MODE=trusted-local-single-tenant`. Unset (`none`) offers no
  local computer: the production default, failing closed. It is **not
  isolation**: one sidecar serves every agent, and a shell can read other agents'
  files, the store, its lock and the sidecar's configuration. Use it only
  where every user is the same trusted operator, such as one developer's
  machine. Any other mode makes the sidecar not ready.
- **`sprites`** is a microVM on a Sprites platform (`SPRITES_URL`),
  one per conversation, named `<prefix>-c<conversation id>` where the prefix is the
  agent's computer name, `<PI_DURABLE__SPRITE_PREFIX>-<environment>-b<agent id>` (the `b<number>` is an
  opaque identifier of a live Sprite; it was the bot's id before the rename). Offered only with
  `SPRITES_TOKEN` and `SPRITES_IMAGE`. The image is `Dockerfile.agent`: the
  pi-env daemon, the relay (`agent/sprite-relay.mjs`) and the screen, started
  and watched by `agent/guest/entrypoint.sh`; no app code or secrets. The
  screen is a browser desktop stack: Xvfb `:99`, openbox, Chromium
  with its profile in the home folder (`~/.config/chromium`, kept across
  sleeps, sandbox on, `--disable-gpu --disable-gpu-shader-disk-cache`) and
  CDP on `127.0.0.1:9222`, x11vnc on `127.0.0.1:5900` (no password; never
  reachable from outside the guest), websockify on `127.0.0.1:6080`, and
  a desktop control server (`agent/guest/server.js`, vendored
  verbatim, control-only) on `127.0.0.1:8090` with a bearer made at each
  boot into `~/.desk-token` (0600). Only the relay listens beyond the guest's
  loopback. `agent/sprites-bridge.mjs` looks the Sprite up,
  creates it if missing (2 vCPU, 2 GiB, 8 GiB disk, asleep after an hour
  idle, never expiring: `idle_destroy_after: '0'`), starts it if stopped or
  cold, waits up to 120 seconds for its entrypoint, then connects to its
  private address. The platform's cold storage moves a disk asleep for 14 days
  to slower storage and brings it back on wake, through the same start; the screen's
  page asks the sidecar first (`GET /v1/conversations/:id/computer`, a lookup
  that wakes nothing) and says "Waking up, this can take a minute" for a cold
  one. At the platform's awake cap for the token's scope, create or start answers 429
  `scope_capacity_exceeded`; the run stops as `computers_busy` ("Too many
  computers are awake; try again shortly"). Nothing is queued and no other
  conversation is put to sleep. Deleting an agent deletes its Sprites, one per
  conversation, with their disks: after the agent is gone, `ComputerRemovalJob`
  sends `DELETE /v1/conversations/:id/computer` for each, and the bridge deletes
  the Sprite (one already gone is fine). It retries while the sidecar is down.
  This is the only way a Sprite goes. The relay starts the daemon only for a connection
  that opens with a secret derived from the token and given to the Sprite at
  creation; pi-env's `RemoteExecutionEnv` drives it. The connection opens
  when a conversation with a Sprite runs (Pi builds the environment for each model
  request and tool call); while open the bridge looks the Sprite up each
  minute, since direct traffic is not activity to the platform, and it exits
  after `SPRITES_IDLE_MS` (60 s) without a request. Nothing of the sidecar's
  environment reaches the Sprite. Nothing here limits where a Sprite may
  reach on the internet: the app sets no egress list. Tested against a loopback stand-in of the API
  (`agent/test/sprites-stand-in.mjs`) and with the built image as a plain
  container; not yet against the platform itself. Rotating `SPRITES_TOKEN`
  changes the relay secret, which a Sprite keeps from its creation: recreate
  its Sprites (their files go with them) or keep the token.

**The screen.** A conversation whose computer is a Sprite that is on has an "Open
screen" button. Its page (`Conversations::ScreensController`) runs noVNC
(vendored, pinned in the importmap) against a websocket to the same address.
Rails checks the signed-in person (their session, and that the conversation is theirs), the
computer and the Origin (`APP__URL`), then relays the websocket
(`async-websocket`) to the sidecar's `GET /v1/conversations/:id/screen`
over its socket. The sidecar wakes the Sprite, dials the relay with
`AGENT-SCREEN <secret>`, forwards the request to websockify and pipes
bytes; while it is open, the bridge looks the Sprite up each minute, which
keeps it awake. You watch and type while the agent works; there is no
takeover mode. Logins made in the screen's Chromium stay in its profile.
The agent uses the same browser: `visit_website` shows the page in one reused tab
there over CDP (`agent/guest/visit.mjs`, the tab's id in `~/.visit-tab`;
headless Chromium when that fails to start), and
the `desktop` tool (screenshot, click, type, key, scroll, drag, wait) goes
through `agent/guest/desk.mjs` to the control server's `/action`. Helpers
never get `desktop`. A saved sign-in is filled into the `visit_website` tab by
`agent/guest/fill.mjs` (`docs/passwords.md`).

**Command connectors.** A person's `command` MCP server runs on each
conversation's computer (`docs/connectors.md`). Rails posts each JSON-RPC message
to the sidecar's `POST /v1/conversations/:id/connectors/:name/rpc`; the
sidecar (`agent/command-connectors.mjs`) keeps one process per conversation and
connector, in its local folder or, through a bridge dialling the relay with
`AGENT-COMMAND <secret>`, in its Sprite as `agent`. While one runs, the
bridge keeps the Sprite awake; after 10 minutes without a call the process
stops and the Sprite may sleep. The image has `nodejs` and `npm` for `npx`
servers; no Python or `uv`.

Settings (`.env.example`): `PI_DURABLE__SIDECAR_URL`, and two distinct tokens,
`PI_DURABLE__SIDECAR_TOKEN` (Rails to sidecar) and `PI_DURABLE__RAILS_TOKEN`
(sidecar to Rails). Blank, short or equal tokens refuse every call. Generate
each with `bin/rails secret`.

An agent may choose only a model on `config/pi_durable.yml`'s list that the
sidecar can run: one of pi-ai's models for a provider it has a key or
subscription for (`GET /v1/models`). The agent's settings offer just those, each
with the thinking levels pi-ai says it supports (`ModelCatalog`, cached ten
minutes; every level when the sidecar can't answer, since the sidecar runs a
model at its nearest supported level). The sidecar never falls back to another
model, and is not ready (`GET /up` answers 503) with no provider at all. `AGENT_MODEL_MODE=local` offers only `local/stand-in`, a free
scripted stand-in (`agent/local-model.mjs`) that understands `remember key:
text`, `forget key`, `notes`, `ask` and `time`. Development
uses it by default (`Procfile.dev` sets `AGENT_MODEL_MODE=local`); tests use
scripted models only.

## Deploying

Each destination (`config/deploy.example.yml`, and an install's own)
has an `agent` role beside `web` and `job`: same host, same image, same
`storage` volume, `proxy: false`, command `bin/agent-container`.

- **Image.** The `Dockerfile` copies the `node` binary from the pinned
  `node:24.20.0-bookworm-slim` image and runs `npm ci --ignore-scripts
  --omit=dev` in `agent/` during the build. npm stays in the build stage. The
  tag is pinned; its digest is not, so pin it before the first deploy.
- **Private reachability.** The sidecar listens on its own container's
  loopback only. `bin/agent-container` forwards a Unix socket on the shared
  volume (`AGENT_SOCKET`, `/rails/storage/agent/sidecar.sock`, mode 0600) to
  it, and web and job reach it at `PI_DURABLE__SIDECAR_URL=unix:///rails/storage/agent/sidecar.sock`.
  Nothing listens on a network interface and no port is published. Kamal
  still attaches the container to its shared `kamal` network; the sidecar
  uses it only to call Rails back at `AGENT_RAILS_URL` (the web role's
  network alias). Those five callback routes (`/agent/accesses`,
  `/agent/invocations`, `/agent/frames`, `/agent/syncs`, `/agent/sign_ins`)
  skip host authorization (`config/initializers/pi_durable_callbacks.rb`), as
  do only `/up` and Campfire's webhook besides; they refuse any request
  without `RAILS_TOKEN`.
- **Tokens.** `.kamal/secrets.<destination>` resolves
  `PI_DURABLE__SIDECAR_TOKEN`, `PI_DURABLE__RAILS_TOKEN` and any provider key
  from their own Passbolt resources (placeholders until created; the
  pre-deploy hook refuses a blank one). Web and job get the two tokens; only
  the agent role gets a provider credential, and it never gets `RAILS_MASTER_KEY`.
- **Subscriptions.** The agent role reaches Claude through a
  Claude subscription, as Pi does after
  `/login anthropic` with the pi-anthropic-auth extension; and OpenAI's Codex
  models through a ChatGPT subscription, as Pi does after
  `/login openai-codex`. No deploy-time API key, and no fallback to one. The app owns its
  own grants: an admitted person signs in once to each at `/subscriptions`
  (Rails' owner console, behind sign-in), which calls the sidecar's
  `/v1/subscriptions/:provider` routes. ChatGPT's sign-in ends on
  `http://localhost:1455/…`, which does not load; the owner pastes that
  address into the console. The sidecar keeps each grant in its own file,
  `CLAUDE_SUBSCRIPTION_FILE` (`/rails/storage/agent/claude-subscription.json`)
  and `CHATGPT_SUBSCRIPTION_FILE` (`chatgpt-subscription.json` beside it),
  mode 0600, left out of `storage.tar`, encrypted with `SUBSCRIPTION_VAULT_KEY`
  for this install (`AGENT_APPLICATION`) and scope (`SUBSCRIPTION_VAULT_SCOPE`,
  unset meaning `DEPLOYMENT_ENVIRONMENT`)
  (`agent/subscription-credentials.mjs`, ported from an earlier
  implementation). A grant sealed for another name or scope stays on disk
  but can't be opened: /subscriptions says to sign in again, and an agent's
  turn stops with "its sign-in can't be opened". To rename the environment,
  first set `SUBSCRIPTION_VAULT_SCOPE` to the old name on the agent role,
  then rename `DEPLOYMENT_ENVIRONMENT`. A sign-in link is one-use and lasts ten minutes; each
  exchange or refresh is recorded before it is sent and never replayed, so an
  interrupted one means signing in again. Never copy another program's grant
  or key here. pi-ai adds Claude Code's identity for the token, and
  `agent/claude-subscription.mjs` adds the extension's billing block;
  `CLAUDE_CODE_VERSION` there follows pi-ai's, raised when Anthropic answers
  `claude_code_version_too_old`. ChatGPT's requests are pi-ai's `openai-codex`
  provider's, unchanged. `agent/test/claude-subscription.test.mjs` and
  `chatgpt-subscription.test.mjs` pin the requests pi-ai builds for each
  grant, so a pi-ai upgrade that changes them fails CI.
- **Lending the Claude subscription (optional).** Two installs on one
  machine may share one Claude subscription. Copying the grant into both
  would not work: each refresh rotates the refresh token, so they would sign
  each other out. Instead the install that signed in, the lender, keeps and
  refreshes the grant as ever and lends only its current access token; the
  other, the borrower, keeps that token at most five minutes (and never into
  the lender's refresh window, its last five), and holds no refresh token.
  The lender answers one route, `GET /v1/lend/anthropic`, on a Unix socket of
  its own, mode 0600, never on a network; the borrower presents
  `CLAUDE_SUBSCRIPTION_LENDING_SECRET` (32 characters or more), set the same on
  both. To set it up:

  1. Make a host folder for the socket, owned by the containers' user
     (uid 1000): `install -d -o 1000 -g 1000 -m 700 /data/docker/claude-lending`.
  2. On both installs' `agent` role, mount it (`volumes:
     - /data/docker/claude-lending:/lending`) and add the secret to the role's
     secrets.
  3. The lender's role sets `CLAUDE_SUBSCRIPTION_LEND_SOCKET:
     /lending/claude.sock`; the borrower's sets
     `CLAUDE_SUBSCRIPTION_BORROW_SOCKET: /lending/claude.sock`. The borrower
     keeps `CLAUDE_SUBSCRIPTION_FILE`, which then holds only its pasted API key.

  The borrower's /subscriptions says whose sign-in it uses (the lender's
  `AGENT_APPLICATION`) and offers no sign-in or sign-out: those happen at the
  lender. With the lender signed out, deploying or down, the borrower's Claude
  models stop as if signed out, with no fallback to an API key, and come back
  on their own. A sidecar that is told to lend but has no grant of its own,
  or borrows itself, is not ready (`claude_lending_invalid`).
  `agent/test/subscription-lending.test.mjs` holds all of this.
- **Claude API key (optional).** Beside the Claude subscription, an admitted
  person may paste an Anthropic API key at `/subscriptions`. It serves only
  the `anthropic-api/…` models, billed per token; `anthropic/…` stays the
  subscription, and neither is a fallback for the other. Rails passes the key
  to the sidecar's `/v1/subscriptions/anthropic-api/key` and keeps nothing
  (`api_key` is a filtered parameter). The sidecar
  (`agent/claude-api-key.mjs`) refuses a subscription token or a malformed
  key, checks the rest with Anthropic's free model list, and seals a good one
  with `SUBSCRIPTION_VAULT_KEY` in `CLAUDE_SUBSCRIPTION_FILE` (else
  `CHATGPT_SUBSCRIPTION_FILE`) under its own namespace, so the grants there
  open as before. Only its last four characters are ever shown. No key does
  not make the sidecar unready; a run on an `anthropic-api` model without one
  stops as `credential_missing`. `agent/test/claude-api-key.test.mjs` pins
  that pi-ai sends it as `x-api-key` with none of Claude Code's identity.
- **Replacement without overlap.** Kamal starts the new container before it
  stops the old one. The new sidecar finds the store owned (`GET /up`
  answers 503 `store_already_owned`); `bin/agent-container` stops it, retries
  every two seconds, and serves only once it owns the store, so two
  sidecars never write one store. It never deletes the lock. Any other
  not-ready reason, or no ownership within `AGENT_OWNER_WAIT` seconds
  (default 120), exits non-zero. Requests in that window get 503.
- **One host.** The lock is a single-host kernel lock. Never give the role a
  second host or move the volume to shared storage.

Nothing here has been deployed or built into an image by the template's
own tests; the Rails tests read the generated deploy files and Dockerfile and
run `bin/agent-container` against a stand-in sidecar.

## Interfaces

The wire between Rails and the sidecar, with what each message promises, is
`docs/design/CONTRACT.md`; it is the only copy.

Browser resources, with CSRF (`config/routes.rb` is the full list):
`agents` (new, create, show, edit, update) and their settings beneath
(`computer`, `concourse_agent`, `campfire_bot`, `prompts`, `skills`,
`routines`, `permissions`); `conversations` (index, show) with
`messages`, `submissions`, `cancellations`, `compactions`, `export`,
`archive`, `screen` (show, and its websocket), `connectors`, and
`invocations/:id/approval`, `.../answer` and `.../sign_in`. A conversation page subscribes to its Turbo stream: messages
append as they are pulled, the live tail and status are replaced by frames,
and a tool call's card is replaced as its ledger row changes. Closing the page
never cancels a run.


## Retained state

The sidecar's store is `AGENT_STORE` (default `storage/agent/durable.sqlite`,
plus its `-wal`/`-shm` files and a `.owner.sqlite` lock beside it). It must
live on a persistent volume, never in the image or a disposable layer.
Ownership is a kernel-held lock on the lock database, not a lease: a second
sidecar on the same store refuses to start, and the lock is released when the
owner exits or crashes. It is a single-host lock. Never share a store between
replicas or hosts, and never delete the lock file to "unstick" a start.

To replace the sidecar (deploy, move): stop the old process and confirm it
has exited before starting the new one on the same store. Unfinished work
resumes at boot without waiting for a browser request.

## Backup and restore

`ops/backup/<app>-backup.sh` includes the store. It stops the agent
container, snapshots the store with `bin/agent-store` inside the web container
(same volume, same lock), snapshots the Rails databases in the same window, so
both come from one point in time, and starts the agent container again on
every path out, success or failure. The staged set gains
`agent-durable.sqlite` and its `agent-durable.sqlite.manifest.json`; the live
store, its lock and the socket are kept out of `storage.tar`. The sidecar is
down for the few seconds the snapshots take. No running agent container, or
one that will not stop, fails the backup. `ops/backup/<app>-restore.sh`
checks the snapshot against its manifest's SHA-256 and with `integrity_check`.

By hand (development, or a host without the script), `bin/agent-store` wraps
`agent/store.mjs`. It takes the same ownership lock as the sidecar, so it
refuses while `bin/agent` runs: stop the sidecar, confirm it exited, snapshot,
start it again.

    bin/agent-store snapshot /path/to/stage/agent-durable.sqlite
    bin/agent-store restore /path/to/stage/agent-durable.sqlite storage/agent/restored.sqlite

A snapshot is a consistent `VACUUM INTO` copy that passes `PRAGMA
integrity_check`, published by rename; its `<snapshot>.manifest.json` (with
the SHA-256) is written last, and a snapshot without one is incomplete.
Restore writes only to a fresh path and checks the digest and integrity
before the store appears. Point `AGENT_STORE` at the restored file and start
one sidecar: pending questions and unfinished tasks come back with it.

Restore the Rails database from the same point in time. If they disagree,
Rails refuses to map a sidecar conversation it already knows under another
request (409) rather than guess. The invocation ledger in Rails is what stops
a replayed tool call from running twice; a Rails database older than the
store can let a committed call run again. The `messages` copy is rebuilt from
the store with `Conversation#resync!`.

To put a snapshot live: stop the web, job and agent roles, restore the Rails
databases and `bin/agent-store restore` the store to a fresh path from the
same set, point `AGENT_STORE` at it (or move it to
`storage/agent/durable.sqlite` while nothing runs), and boot all three.

Off-host copies have the same gap as the rest of the app (S11): a host whose
borgmatic cannot reach another host's stage has no generic pull yet, so the
agent snapshot, like the databases, stays on that host.

## Limits

- A local computer's directory is not a sandbox (above). A Sprite is
  a microVM, isolated from the app's files, but not yet tried on the platform.
- A local computer's files live under `storage/agent/computers/` and travel
  in `storage.tar`; a Sprite's files stay on the Sprite, in no backup of this
  app.
- Shells start with a minimal environment, but nothing here is an operating
  system egress firewall.
- The deployment above is configuration only. The template's tests never
  build the image or deploy it; the first real deploy is a deliberate step.
  An install reaches Claude and ChatGPT through subscriptions (above), not
  deploy-time keys; an Anthropic API key pasted in the console is optional.
