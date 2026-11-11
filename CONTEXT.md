# durable-assistants Context

The domain: what the words mean, what the data is, and what was decided and why.
`AGENTS.md` holds the rules for changing the code; this file holds what the code
is about. It started as an omakase Rails template's skeleton, so the tables below
begin with what every app has and grow with the domain.

## Vocabulary

| Term | Meaning |
|---|---|
| durable-assistants | The project, and this repository: a multi-tenant Rails template in which people define, configure and run their own agents (assistants). The plan of record is `docs/design/PLAN.md`. |
| Deployment | One running install of the project, with its own address, admitted people, sign-in provider, model accounts, Concourse server and Google app. These are settings of the deployment; another deployment can differ. |
| Install | One deployment's configuration, kept outside this repository: a Dockerfile `FROM` the published image at one commit, its credentials and starter agent, destinations, secrets and backup units (`docs/deployments.md`). |
| Agent | One thread with its own context: name, instructions, model, thinking level, time zone, tools, skills, notes, computer and screen. Agent, assistant and conversation are one thing; screens say only "agent". A person's first sign-in gives them the install's starter agent, unless an agent already has its name or address: the starter is made once, and anyone after starts empty with "New agent". "New agent" asks for a name and an address (which follows the name until the person types their own), and starts from the install's starter, on the model and thinking level of the person's most recently used agent (the starter's for their first, or when that model is no longer offered); its name and email address are fixed when it is made (an address that changed would strand every thread it is in); an optional title ("Chief of Staff"), which may change, sits beside its name in both lists and is told to it under its name; the agent rewrites its own instructions when asked (`change_yourself`, approved each time). Switched on in its Tools, an agent can make another the same way when asked (`make_agent`, approved each time with exactly what will be made); no tool deletes one, and nothing sends a new agent to Concourse unless the person asks (`join_concourse`), so an install may keep one agent as its gateway. It has an email address where the install has email. Deleting it asks for its name typed, and takes its thread, its address and its Sprites with it. Mail from Concourse and email reaches its thread through one seam (Channel). |
| Office | The services every install runs beside the app, where its people and agents work together: chat (Campfire), wiki (Outline), code (Forgejo), CRM (Twenty) and vault (Passbolt). The template owns them (`config/deploy.example.yml`, `config/install_connectors.yml`); the person's own tools come as connectors or through a computer. `docs/office.md`. |
| Starter agent | The agent every new person starts with, made from `config/agents/<APP__STARTER_AGENT>`; the template's is `config/agents/assistant`. |
| Conversation | An agent's thread (`Agent#conversation`, no parent). One thread is one agent: branches are no longer made, though an install may keep old ones (`docs/design.md`, "One conversation, one agent"); "New agent from here" makes a new agent whose thread starts as a copy of another's up to a reply. Its durable state lives in the sidecar, which admits it the first time it is used; Rails keeps the mapping and a copy of its messages. A code name only: screens never say "conversation". |
| User | A person who has signed in through Ajent, identified by the OIDC `sub`. The app stores no passwords. |
| Ajent | The identity provider (`OIDC__ISSUER`). It says who someone is; the app decides what they may do. Another install may name another OIDC provider in settings. |
| Admission | The list of verified emails (`ACCESS__EMAILS`) the app lets in, asked on every request. Ajent proves who; Admission says who comes in. Its admins (`ACCESS__ADMINS`) may also manage the model accounts every agent shares; everyone else is an ordinary user. |
| Destination | A Kamal deploy target of a deployment, in the install's `config/deploy.<name>.yml`. One whose file says `x-express: <VARIABLE>` deploys only when that variable is 1. The template has only `config/deploy.example.yml`. |
| Role | A Kamal server role. `web` runs Falcon; `job` runs Solid Queue (`bin/jobs`). Both boot the whole app. |
| Setting | A value read with `Rails.app.creds.option(:service, :key)`: ENV `SERVICE__KEY` first, then encrypted credentials. Listed in `.env.example`. |
| Process knob | A plain ENV variable that tunes a process (`PORT`, `JOB_CONCURRENCY`, `OTEL_*`). Not a setting; never from credentials. |
| Revision | A kept copy of an agent's instructions, model and tools from before an edit. |
| Message | Rails' copy of one committed entry of a conversation, pulled from the sidecar and rebuildable from it. |
| Tool | Something an agent can do, as a Ruby class with one JSON Schema. Some ask the person first. |
| Invocation | One tool call, recorded once, with its outcome. A replay returns the outcome; a changed replay is refused. |
| Approval / Answer | A person's decision on a call that asked first, or their answer to an agent's question. |
| Document | What an agent and the person write together in the canvas beside its thread: a title, a kind (Markdown, or code in a language) and its versions, each saying who wrote it. Its body is its newest version. |
| Note | Something an agent was asked to remember, by key. Its memory: the thread is not, since compaction drops it. Its instructions list its newest 50 notes by key and the day each changed, never a body, so it knows what it has; it reads one with `list_notes`. |
| Routine | What wakes an agent: a prompt sent to its thread on a schedule ("every weekday at 8am", in its time zone, at most every 5 minutes). The agent adds and removes them when asked, with the person's approval; its Routines settings list them to pause or delete. `RoutineJob` runs a due one only while the agent is idle, and a missed run happens once. An agent's soul (instructions), memory (notes) and schedule (routines) are all set by asking it and shown in its settings. |
| Computer | Where a conversation's file and shell tools run: a folder on this machine (trusted, local only), a Sprite (a microVM on a Sprites platform), or a folder on a real machine over SSH, as one of its users and not isolated (`docs/computers.md`). A Sprite is per conversation, made when first used; the agent's `Computer` row is the template. Off means the agent's conversations have no files or shell. |
| Channel | A way in and out for others than the person: Concourse, email, Campfire, texts (`docs/phone.md`; in by email). In, a class that calls `Conversation#receive` with the sender and how to answer; out, a tool. `docs/email.md`. |
| Saved sign-in | A site's username and password that people keep in the install's own Passbolt and share with the agents' one Passbolt user. An agent fills one into its browser after the person approves, or asks the person to save one it lacks through a form it never sees; the model never reads it. `docs/passwords.md`. |
| Connector | Another service's tools (`McpServer`): a remote MCP server's web address, its encrypted headers or sign-in, and the tools it last listed. A person's own reach all their conversations; a conversation's own replace or switch off one of the same name. Rails is the client. Contract: `docs/connectors.md`. |
| Concourse | The agents' mail network an install names (`CONCOURSE__ORIGIN`), if any: one server per install. An agent on it has a Concourse identity (`ConcourseAgent`), e.g. `acme/iris` in organization `acme`, with its own machine client, made when the person joins it and an owner of the organization approves. Only agents in the same organization see each other. |
| Network | One organization on Concourse, as the agent and the person read it ("Join another network", the `network` argument). An agent may hold one identity in each of several, each its own trust boundary: a task stays on the network it came or went on, a new send names its network once there are two, and nothing here bridges two. A task from before networks is the agent's first's. |
| Peer task | A Concourse task linked to the conversation it belongs to (`PeerTask`): inbound, a peer's request the conversation answers with `concourse_reply`; outbound, one it sent with `concourse_send`. |
| Device | A browser where a person turned notifications on in Settings (`Push::Subscription`): its push service's address and keys. Removed when the push service says it is gone. |
| Share | What the phone's Share sheet handed the installed app (words, a link, pictures), kept for the person until they send it from an agent's composer, or for a day. |
| Sidecar | The Node process running Pi Durable. Infrastructure only: it holds no business logic (`docs/agent.md`). |

## Data model

SQLite, four production databases on one volume: `production` (the record),
and `production_cache`, `production_queue`, `production_cable` (Solid Cache,
Queue and Cable). All four are backed up nightly; only `production` is the
record. Active Storage files live on the same volume and travel in
`storage.tar`.

Every record is owned (reached through its owner), reached through an owned
record, or deliberately global, and `test/tenancy_scoping_test.rb` fails until
it is placed.

- `User` owns `Agent`s, `Conversation`s, connectors (`McpServer`, with an
  optional conversation), devices (`Push::Subscription`) and `Share`s (each
  with its pictures). A request reaches any of them only through
  `Current.user`.
- `Agent` owns its `Agent::Revision`s, `Note`s, `Document`s (each with its `Document::Version`s), `Permission`s, conversations, at most one `Computer`
  and its `ConcourseAgent`s, at most one per organization (each client secret
  encrypted; access tokens only in the cache).
- `Conversation` (user, agent) owns its `Invocation`s, `Message`s and `PeerTask`s.
- `Invocation` has at most one `Approval` or `Answer`, each naming the person
  who decided.

## Decisions

- **Falcon, not Puma.** A request is a fiber, so a slow upstream call holds no
  thread. Solid Queue runs in its own `job` role because Falcon has no
  in-process worker; the web container migrates on boot.
- **Edge Rails, one pinned SHA.** Moved deliberately, with `bin/ci` green.
- **Ajent is the sign-in boundary, and the only door.** OIDC with PKCE and RS256
  pinned; the app stores no passwords. The client is an application at the
  provider whose redirect URIs equal each destination's `OIDC__CALLBACK_URI`.
  People are keyed by `sub`; admission is by verified email, on every request.
  Sign-in fails closed. No header identifies anyone (a Sprite can write any).
- **A product image, and installs as configuration.** This repository holds
  generic code only and publishes an image from every green commit on main;
  each deployment is an install that pins one and keeps its own
  destinations, secrets and credentials (`docs/deployments.md`). Nobody
  merges this code into an install. Production
  is gated: a deploy there must be expressed, never implied.
- **One credentials file, one master key, per install.** ENV carries clear per-destination
  configuration and the values that differ by destination; everything else is in
  the credentials the master key unlocks.
- **Real client IP.** Every destination is reached through a Cloudflare
  Tunnel and its firewall admits nothing else, so the visitor is the address
  Cloudflare's edge wrote into `X-Forwarded-For`. Cloudflare's own ranges are
  not trusted: other customers' Workers come from them too.
- **Privacy.** Request bodies and stack-frame locals are scrubbed by
  `lib/durable_assistants/glitchtip.rb`. `lib/durable_assistants/telemetry/exporter.rb` keeps
  operational span attributes and strips raw URLs, event/link payloads and status
  descriptions before export to the pass-through collector. Rails filtering
  alone misses unmatched requests and outbound HTTP. Resource configuration
  and retained operational labels must not contain user content. Rybbit's tag
  (`AnalyticsHelper#rybbit_tag`) is on every page, sign-in included, once
  `RYBBIT__SITE_ID` is set. Replay is the Rybbit site's own setting; masking
  typed input is `RYBBIT__REPLAY_MASKING`, off by default, and password
  fields, where every secret is pasted, are masked either way. There is no
  Content Security Policy to widen.
- **Ahoy counts what people did.** Visits and four server-side events (Agent
  created, Message sent, Approval answered, Connector added) go to the app's
  own `ahoy_visits` and `ahoy_events`, on the person once signed in. Events
  carry ids and choices, never words; addresses are masked; there is no ahoy.js
  and no beacon route. The sidecar's callbacks, webhooks and pushes are not
  visits (`config/initializers/ahoy.rb`).
- **One accent, set by the install.** `APP__ACCENT_HUE` is the only look an
  install chooses; every shade comes from it, and a bad value fails the boot.
  The icon is drawn in it too, at request time, so no image is per install.
  An install asks not to be indexed (robots.txt, header and meta). The thread
  reads as Messages (docs/design.md), in the system's own fonts.
- **Backups prove restore.** The backup script snapshots, integrity-checks and
  publishes atomically; the restore script restores into a scratch directory and
  verifies it; a test runs both on real SQLite files.
- **A generic agent, defined in Rails.** An agent is a row, not code; its tools
  are Ruby classes in an explicit catalog; the sidecar receives the whole
  definition with each message.
- **Calendars over CalDAV, each agent its own account.** Five calendar tools
  read and write the install's CalDAV server as the agent's account, keeping
  no copy; a write names the version read, and the server expands repeats.
  Inviting outsiders asks first. `docs/calendar.md`.
- **Outside tools through MCP, with Rails as the client.** An agent's MCP server
  tools join its definition as `mcp__<server>__<tool>` (`Tool::Mcp`) and run
  through the `Invocation` ledger like any tool: committed as running, then
  called in a job with no transaction open (`effect :external`), while the
  sidecar holds a wait as it does for a person. Only a tool the server
  marks read-only runs without asking. MCP has no idempotency key, so a crash
  between the call and its record can repeat it; approval limits the damage.
  Headers, tokens and sign-ins are encrypted with keys derived from
  `secret_key_base` unless credentials set `active_record_encryption`.
- **Concourse, natively.** `DurableAssistants::Concourse::Client` (lib/) is the
  only code that speaks Concourse. An agent on Concourse has `concourse_find`,
  `concourse_get`, `concourse_send` (asks first; its A2A messageId names the
  call, so a repeat is the same message) and `concourse_reply` (only a task
  linked to the conversation, with an explicit state). On several networks,
  each identity reads and follows only its own tasks, and every task is
  answered through the identity it came on. Mail arrives in the job role:
  `ConcourseListenJob` reads Concourse's event log and delivers each task an
  event names at once; `ConcourseSweepJob` every minute reads the inbox for
  anything the log missed. Where `APP__URL` is public https, connecting registers
  a push (`PUT api/push_config`, a fresh token each time): Concourse posts a
  notice with no mail to `/concourse/:id/push`, which wakes one read of the log,
  and no listener holds a worker open. Elsewhere, or if Concourse refuses, the
  listener long-polls as before. Put that path outside Cloudflare Access. Each caller and context
  gets its own conversation; peer text is marked as untrusted peer mail.
- **Joining Concourse is one click, not pasted credentials.** The person
  approves on Concourse's own page and Rails redeems a one-time code (PKCE,
  `state` in the session) for the agent's machine client; an agent waits for
  an owner's approval before it reads mail, and Disconnect has Concourse retire
  it. Credentials pasted before keep working. `docs/design.md`, "Joining Concourse".
- **Settings are one place, shaped as a Mac's System Settings**.
  Everything a person sets (themselves, the models every agent shares, the
  connectors, and each agent's sections) is under `/settings`, one REST
  resource per section rendered in one layout (`layouts/settings`): no
  settings controller holds another's logic. A small setting saves as it
  changes; long text has Save and warns before it is lost. A tool can be
  switched off for every agent on its connector (`McpServer#disabled_tools`)
  or for one agent (`Agent#disabled_tools`, or its catalogue `tool_names`
  and `capabilities` for a built-in); `Agent#tools` leaves both out, loaded
  or looked up, and the Tools meter counts what the next message carries
  against the sidecar's limit of 64. Models are named in words with who pays
  ("Claude Haiku 5.5 · Subscription"), the route under Advanced.
- **The canvas is one record, and Rails tells the agent what the person changed**.
  A `Document` belongs to the agent, as its notes do, so its old branches share it;
  every save is a `Document::Version` (agent or person), and a restore is a new
  one. The agent writes with `write_document`, prefers `edit_document`'s
  exact-once replacements, and reads with `read_document`, none asking first.
  The person's next message carries a unified diff of their edits since the
  agent last saw each document, built in Ruby (`Document::Diff`), so the
  sidecar is unchanged. There is no HTML or SVG preview: sandboxed with
  `allow-scripts` and a no-network policy, a preview still navigated itself
  and opened WebRTC connections, so a page is shown as its source.
- **SQLite, one sidecar, one store.** The Rails 8 default and the template's
  standard; each conversation is a durable object inside the one store.
- **A thread is read in pages.** An agent is one thread for life, so nothing
  that runs on a page load reads all of it. The thread page shows the newest
  40 turns (`Conversation::Page`); earlier ones load in a lazy frame as the
  person scrolls up, and a page never parts a tool call from its result. The
  sidecar's `GET /v1/conversations/:id` carries no history, and its export
  streams a store page at a time. Summaries keep the model's context inside
  its window however long the thread runs (`agent/test/parity.test.mjs`).
  A 5,000-message thread's page went from about 5 s and 8 MB to under 0.1 s
  and 115 KB.
- **A request asks as pi asks.** A tool that changes something outside the
  agent asks first: Allow once, Always for this agent, Always with this
  recipient (an email address, a Concourse agent, a Campfire room), or Deny.
  An "Always" is a `Permission`, listed and removable in the agent's Permissions. It
  is made only by the person's answer, and what it covers comes from the call
  as recorded, never the form, so nothing the agent reads can widen it. A call
  reaching one recipient more asks again. A change to the agent itself and a
  password fill ask every time. Tools that only read never ask. An install
  may allow everything (`APP__APPROVALS=allow`): every approval, these
  included, runs at once for every agent, except what asks every time (an
  iMessage from the person's phone). `APP__APPROVE_EVERYTHING=true` goes
  further: no call waits for a card. Every call is still recorded in its
  thread, and questions and sign-ins still wait.
- **Notifications: Rails decides when, the device whether**: an agent that needs the person or finished a reply, opted into per device in Settings; the service worker skips a reply on the thread already in front.
- **The badge counts agents waiting on the person**, re-broadcast whenever a thread starts or stops waiting.
- **The Share sheet sends nothing by itself**: its post is let in by `Sec-Fetch-Site: none` and fills an agent's composer for the person to send.
