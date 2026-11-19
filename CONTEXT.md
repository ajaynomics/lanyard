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
| Workspace | The boundary for everything an agent can reach (`docs/design/workspaces.md`). Every agent belongs to exactly one, for life. Each person has a personal one (`User#personal_workspace`), which shows their name; a shared one has its own name and many members. A request works in one, `Current.workspace`: the one its record or address names (`/workspaces/:id/connectors`), otherwise the one they used last (`session[:workspace_id]`) while the person belongs to it, their personal one otherwise. The agents list shows every one the person is in, a group each (`Workspace::Group`) with its own menu, so nobody switches to see one; opening an agent, its thread, a card or a workspace's own page works there, and that becomes the one they used last, where the list's New agent starts unless they choose another. |
| Payer | The workspace whose model account a workspace's calls are billed to (`Workspace#payer`): none, the install's, as before; itself; or another workspace, chosen by someone who owns both. The calls still run on the install's model accounts; the payer says whose they are billed to. `docs/billing.md`. |
| Model usage | What one model or tool used in one run or background helper (`ModelUsage`): tokens and an estimated cost, against the workspace and agent that made the calls and the payer then, never worked out again from later settings. A workspace's members see its own on its Usage page. |
| Membership | A person in a workspace (`Workspace::Membership`), as its `owner` (exactly one) or a `member`. Both use the workspace alike; only the owner invites, removes and cancels invitations, and hands the workspace to a member, staying as a member; a member may leave. |
| Shared instructions | What every agent of a workspace follows beside its own instructions (`Workspace::SharedInstructions`), read by its model as a labelled section after its own. Only the workspace's owner changes them, on its page; a member proposes a change there (`Workspace::Proposal`) and an agent through `change_yourself` with scope "workspace", which only the owner may allow, every time. Each change is a `Workspace::Revision`, naming who made it and who proposed it. |
| Sole contact | The one agent of a workspace a member chose to hear from (`Workspace::Membership#sole_contact`). No other agent of it sends to their email or the mobile number they gave, nor mails them its cards: the send is refused, naming the agent to go through, even where everything is approved. `docs/contacts.md`. |
| Contact route | An outside email address or number the owner of a workspace routed to one of its agents (`Workspace::ContactRoute`): their mail and texts to any agent of the workspace reach that one alone, saying so. `docs/contacts.md`. |
| Workspace's own key | A shared workspace's own address and key for one of the install's connectors (`Workspace::InstallConnector`), which only its owner sets: its connector uses them instead of the install's, and no other workspace's does. `docs/office.md`, "A workspace's own key". |
| Invitation | An email the owner of a shared workspace invited (`Workspace::Invitation`). Once an admin approves it (the inviter, being one, as it is made; otherwise another admin in Settings, Invitations), it admits the email, and the install emails it, until the person signs in with it verified, when it becomes their `member` membership, or until it is cancelled. |
| Import | Another install moved in as a shared workspace (`Workspace::Import`, `docs/import.md`). It records which copy came, from which release, and the report of what came and what stayed behind. |
| Ajent | The identity provider (`OIDC__ISSUER`). It says who someone is; the app decides what they may do. Another install may name another OIDC provider in settings. |
| Admission | The list of verified emails (`ACCESS__EMAILS`) the app lets in, asked on every request, and the emails a shared workspace invited, with an admin's approval, or has as members (not where the install serves one person). Ajent proves who; Admission says who comes in. Its admins (`ACCESS__ADMINS`) may also manage the model accounts every agent shares, and approve the invitations to workspaces; everyone else is an ordinary user. |
| Destination | A Kamal deploy target of a deployment, in the install's `config/deploy.<name>.yml`. One whose file says `x-express: <VARIABLE>` deploys only when that variable is 1. The template has only `config/deploy.example.yml`. |
| Role | A Kamal server role. `web` runs Falcon; `job` runs Solid Queue (`bin/jobs`). Both boot the whole app. |
| Setting | A value read with `Rails.app.creds.option(:service, :key)`: ENV `SERVICE__KEY` first, then encrypted credentials. Listed in `.env.example`. |
| Process knob | A plain ENV variable that tunes a process (`PORT`, `JOB_CONCURRENCY`, `OTEL_*`). Not a setting; never from credentials. |
| Revision | A kept copy of an agent's instructions, model and tools from before an edit. |
| Message | Rails' copy of one committed entry of a conversation, pulled from the sidecar and rebuildable from it. Each message sent since speakers were kept carries who said it, from its entry: its request id and its author, a person or a channel's sender (`Message#author`, `Message#incoming`). One from before is read from its words. |
| Submission | One explicit send's prepared envelope (`Conversation::Submission`), owned by its conversation and named by the caller's request ID. Until accepted, it holds the exact payload to retry; afterward it retains the receipt, digests and captured context references. It is not a draft queue: nothing sends it automatically, save that resuming a paused agent sends what it held. |
| Paused / held | An agent the person paused (`agents.paused_at`, `Agent::Pausable`) runs no model turn and spends nothing: Rails refuses the sidecar's access check, which the sidecar makes before every tool call and model request, so a turn under way stops at its next step and cards waiting on the person stay. What anyone sends it meanwhile is held: its envelope (Submission) is prepared and not sent, and what was already waiting in the sidecar is taken back to be held too. Only its own thread holds; an old branch thread refuses a send meanwhile. The thread lists them with Drop (only while paused); resuming lets it run and sends them all, in order, once, holding what comes meanwhile until they have gone (`agents.resumed_at`). `docs/agent.md`, "Pausing an agent". |
| Tool | Something an agent can do, as a Ruby class with one JSON Schema. Some ask the person first. |
| Invocation | One tool call, recorded once, with its outcome. A replay returns the outcome; a changed replay is refused. |
| Dispatch | One message a call handed to an outside provider, recorded with its own key before the provider is asked (`Dispatch`). A call that has one never sends again, and the same words to the same recipient are refused while the first is being checked or just went. A send whose answer never came is looked up at the provider until it is listed, and the agent is told; one never listed is never called "not sent" but stays unknown until a person who checked says on its card whether it went. Texts (`docs/phone.md`), Concourse sends (`docs/design.md`), iMessages (`docs/imessage.md`), and mail, whose Message-ID is chosen first and looked for only in the Sent folder of the account it went through (`docs/email.md`), so far. |
| Approval / Answer | A person's decision on a call that asked first, or their answer to an agent's question. The agent that raised a card may take it back while it waits (`withdraw_card`, a question's `withdraw_question`): it then reads "Withdrawn", leaves Needs you, and can never be allowed, so an approval arriving after it is refused and the call never runs (`docs/agent.md`, "Steers and cards"). |
| Run / attention | Two facts about where a thread stands, kept apart (`Conversation::Activity`): whether the agent's own run goes (`execution_status`, from the sidecar) and whether a card waits on the person (the ledger). The thread shows waiting while a card waits, else the run; a card never starts or ends a run. |
| Document | What an agent and the person write together in the canvas beside its thread: a title, a kind (Markdown, or code in a language) and its versions, each saying who wrote it. Its body is its newest version. A deleted one is kept, saying when and by whom, for 30 days to be restored. |
| Note | Something an agent was asked to remember, by key. Its memory: the thread is not, since compaction drops it. Its instructions list its newest 50 notes by key and the day each changed, never a body, so it knows what it has; it reads one whole with `list_notes` and its exact key. A list shows only the first 2,000 characters of a longer note, marked cut, because `remember_note` replaces the whole note and a preview saved back would lose the rest. |
| Routine | What wakes an agent: a prompt sent to its thread on a schedule ("every weekday at 8am", in its time zone, at most every 5 minutes), or once at a time ("Thursday at 3", `once_at`), after which the one-off is deleted. The agent adds and removes them when asked, with the person's approval, every time, even where the install approves everything; its Routines settings list them to pause or delete, a one-off as "once, Thu 19 Nov at 15:00" to cancel. `RoutineJob` runs a due one only while the agent is idle, and a missed run happens once; while the agent is paused, one run of it is held, however many come due. An agent's soul (instructions), memory (notes) and schedule (routines) are all set by asking it and shown in its settings. |
| Computer | Where a conversation's file and shell tools run: a folder on this machine (trusted, local only), a Sprite (a microVM on a Sprites platform), or a folder on a real machine over SSH, as one of its users and not isolated (`docs/computers.md`). A Sprite is per conversation, made when first used; the agent's `Computer` row is the template. Off means the agent's conversations have no files or shell. |
| Channel | A way in and out for others than the person: Concourse, email, Campfire, Telegram (`docs/telegram.md`), texts (`docs/phone.md`; in by email). In, a class that calls `Conversation#receive` with the sender and how to answer; out, a tool. `docs/email.md`. |
| Mail account | An agent's own mailbox elsewhere (`Agent::MailAccount`), which only its workspace's owner sets: the address it sends from, the SMTP server and the name of the saved sign-in holding the mailbox's password, which stays in the vault and is read for each message. With it `send_email` goes from that address through that server; without it, as before. With an incoming server beside the mail server, new mail in its inbox reaches the agent's thread alone, as untrusted mail, once whichever box it came from. Its "Always Bcc" gets a blind copy of everything the agent sends, which the agent neither sees nor changes. `docs/email.md`, "Its own mail account". |
| Calendar server | Where an agent's own calendars live when not on the install's CalDAV server (`Agent::CalendarServer`), which only its workspace's owner sets: the account's calendar home and the name of the saved sign-in holding its password, read for each request. Set, it replaces the install's account for that agent. `docs/calendar.md`, "Its own calendar server". |
| Saved sign-in | A site's username and password that people keep in the install's own Passbolt and share with the agents' Passbolt user: the agent's own, else its workspace's (`Workspace::VaultUser`), else the install's one shared user. An agent fills one into its browser after the person approves, or asks the person to save one it lacks through a form it never sees; the model never reads it. `docs/passwords.md`. |
| Sign-in link | A one-time link for someone outside the install to type a sign-in straight into one empty vault entry (`SignInLink`), which an agent asks for (`ask_outside_for_sign_in`), the person approves every time, and the agent sends on. Opening it only shows the form; its first submit uses it up and writes; it lasts 30 minutes and the person may revoke it. Only its token's digest is kept, and nothing typed; the agent hears only filled, not filled, or expired unused. `docs/passwords.md`, "From someone outside". |
| Connector | Another service's tools (`McpServer`): a remote MCP server's web address, its encrypted headers or sign-in, and the tools it last listed. A person's own reach all their conversations; a conversation's own replace or switch off one of the same name. Rails is the client. Contract: `docs/connectors.md`. |
| Core / lookup | Whether a connector's tools are in every message an agent reads (core) or found when needed (lookup). Its built-ins outside a small core (`Tool::Catalog::CORE`) are lookup too. Each agent decides for itself (`Agent::CoreConnector`, on its Tools): a person's connector is lookup for an agent until made core for it. A lookup connector's tools are reached with `find_tools` and `use_tool`, or from a code mode script with `searchTools()` and `tools.<name>(...)`, with the same approvals and switches. A connector whose refresh no longer fits beside an agent's other tools moves to lookup for that agent alone, recorded (`Agent::ConnectorMove`) and shown on its Tools. `docs/connectors.md`. |
| Concourse | The agents' mail network an install names (`CONCOURSE__ORIGIN`), if any: one server per install. An agent on it has a Concourse identity (`ConcourseAgent`), e.g. `acme/iris` in organization `acme`, with its own machine client, made when the person joins it and an owner of the organization approves. Only agents in the same organization see each other. |
| Network | One organization on Concourse, as the agent and the person read it ("Join another network", the `network` argument). An agent may hold one identity in each of several, each its own trust boundary: a task stays on the network it came or went on, a new send names its network once there are two, and nothing passes between two but a send a person approved. A task from before networks is the agent's first's. |
| Home network, bridge | A workspace's own Concourse organization, named by its owner (`Workspace#concourse_home`). An agent's identity in any other is a bridge: it speaks there once the owner approves it, and each send onto it asks a person (`ConcourseAgent::Bridge`). |
| Helper | A child conversation an agent hands one self-contained task to (`subagent`, the Helpers capability): the agent itself without helpers or the screen, with the same tools and approvals. It answers within the call, or, started in the background, works while the agent carries on, and its answer arrives as a message (`Helper`, `docs/agent.md`). The agent's Stop leaves a background helper running; on its line the person sees its newest step, tells it something (as the agent can, with `message_helper`), or cancels it (as the agent can, with `cancel_helper`; `check_helper` shows it its progress). The Helpers panel lists them too, working first, then those that ended lately: in each agent's settings for its own, and under Settings for all the person's agents. |
| Workflow | A job of several steps an agent sets out as a plain object (`run_workflow`, with Helpers): a fan-out gives every step to its own helper at once and gathers their answers; a pipeline runs them in order, each given the answer before. Each time it runs is a `Workflow::Run` of `Workflow::Step`s, each a background helper; the person watches it on the call's line or in the Helpers panel and may cancel it from either, or tell a step's helper something from the panel, and the agent hears every answer in one message (`docs/agent.md`). |
| Peer task | A Concourse task linked to the conversation it belongs to (`PeerTask`): inbound, a peer's request the conversation answers with `concourse_reply`; outbound, one it sent with `concourse_send`. |
| Device | A browser where a person turned notifications on in Settings (`Push::Subscription`): its push service's address and keys. Removed when the push service says it is gone. |
| Watch | An Apple Watch a person reaches their agents from, with a token of its own that the iPhone app asked for and handed over (`Watch`; `docs/design.md`, "The Watch, with its own token"). Rails keeps only the token's digest. Settings lists each with its last use, and Revoke. |
| Share | What the phone's Share sheet handed the installed app (words, a link, pictures), kept for the person until they send it from an agent's composer, or for a day. |
| Sidecar | The Node process running Pi Durable. Infrastructure only: it holds no business logic (`docs/agent.md`). |

## Data model

SQLite, four production databases on one volume: `production` (the record),
and `production_cache`, `production_queue`, `production_cable` (Solid Cache,
Queue and Cable). All four are backed up nightly; only `production` is the
record. Active Storage files live on the same volume and travel in
`storage.tar`.

Every record is owned by a workspace (reached through its owner), a person's
own, reached through an owned record, or deliberately global, and
`test/tenancy_scoping_test.rb` fails until it is placed.

- `Workspace` is a tenant root, reached through a person's membership
  (`User#workspaces`). It owns its `Agent`s (`agents.workspace_id`, required)
  and their `Workspace::Membership`s, `Workspace::Invitation`s, `Workspace::InstallConnector`s and `Workspace::Import`, and its
  shared instructions' `Workspace::Revision`s and `Workspace::Proposal`s. A request reaches an agent, and
  everything of it, only through `Current.workspace.agents` (or
  `conversations`, `invocations`, `messages`, `helpers`, `workflow_runs`):
  who made an agent (`agents.user_id`) never reaches it, and nor does a
  person's membership of another workspace. Its live lists and each agent's
  and thread's streams go through `WorkspaceStreamsChannel`, which only its
  members may subscribe to.
- `User` keeps what is their own: connectors (`McpServer`, with an optional
  conversation), devices (`Push::Subscription`, `Push::Device`), `Watch`es,
  `Share`s (each with its pictures) and Campfire rooms. Connectors and rooms
  move to the workspace later.
- `Agent` owns at most one `Agent::MailAccount`, at most one `Agent::CalendarServer`, its `Agent::CoreConnector`s and `Agent::ConnectorMove`s (each naming one of its person's connectors), its `Agent::Revision`s, `Note`s, `Document`s (each with its `Document::Version`s), `Permission`s, conversations, at most one `Computer`
  and its `ConcourseAgent`s, at most one per organization (each client secret
  encrypted; access tokens only in the cache).
- `Conversation` (its agent's; `conversations.user_id` is written, never read) owns its `Conversation::Submission`s, `Invocation`s, `Message`s, `PeerTask`s, `Helper`s, `SignInLink`s (each naming the call that made it) and `Workflow`s (each with its `Workflow::Run`s and their `Workflow::Step`s).
- `Invocation` has at most one `Approval` or `Answer`, each naming the person
  who decided, and at most one `Dispatch`, what it handed to a provider,
  naming the person who said whether it went when only a person could.

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
  read and write the install's CalDAV server as the agent's account, or the
  server of its own its workspace's owner names (`Agent::CalendarServer`,
  signed in from the vault), keeping
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
  anything the log missed, every five minutes for an agent Concourse pushes
  to. Where `APP__URL` is public https, connecting registers
  a push (`PUT api/push_config`, a fresh token each time): Concourse posts a
  notice with no mail to `/concourse/:id/push`, which wakes one read of the log,
  and no listener holds a worker open. Elsewhere, or if Concourse refuses, the
  listener long-polls as before. Put that path outside Cloudflare Access. Each caller and context
  gets its own conversation; peer text is marked as untrusted peer mail. On a
  task the agent sent, each peer message with words arrives once, by its id: a
  progress note while the peer works, then its question or its end; a bare
  change of state wakes nobody.
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
  and `capabilities` for a built-in); `Agent#tools` leaves both out, core
  or looked up, and the Tools meter counts what the next message carries
  against the sidecar's limit of 64. Models are named in words with who pays
  ("Claude Haiku 5.5 · Subscription"), the route under Advanced.
- **The canvas is one record, and Rails tells the agent what the person changed**.
  A `Document` belongs to the agent, as its notes do, so its old branches share it;
  every save is a `Document::Version` (agent or person), and a restore is a new
  one. The agent writes with `write_document`, prefers `edit_document`'s
  exact-once replacements, reads with `read_document`, finds one by title with
  `list_documents` and deletes with `delete_document`, none asking first. A
  deletion is soft (`Document::Deletable`): the document leaves every list,
  read and tool, a person restores it from Recently deleted for 30 days, then
  `DocumentPurgeJob` removes it. Listing and deleting are looked up, not
  declared, so they cost no agent a place under the limit of 64.
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
  further: no call waits for a card. These are only the default: each
  workspace's owner may choose its own policy, such as the normal one, where
  what reaches other people and a change to the agent itself ask first
  (`Workspace::ApprovalPolicy`). Every call is still recorded in its
  thread, and questions and sign-ins still wait.
- **Notifications: Rails decides when, the device whether**: an agent that needs the person or finished a reply, opted into per device in Settings; the service worker skips a reply on the thread already in front.
- **The badge counts agents waiting on the person**, re-broadcast whenever a thread starts or stops waiting.
- **The Share sheet sends nothing by itself**: its post is let in by `Sec-Fetch-Site: none` and fills an agent's composer for the person to send.