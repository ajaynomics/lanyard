# Connectors

A connector is an MCP server whose tools a workspace's conversations use: a remote one
at a `url`, or a `command` that runs on each conversation's own computer. The
contract is pi's own `mcp.json` server entry, so an entry that works in pi
works here, within the limits below. Pi's documentation:
[Configure servers](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md#configure-servers) and
[Authenticate with OAuth](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md#authenticate-with-oauth).

## Levels

| pi | durable-assistants |
|---|---|
| `~/.pi/agent/mcp.json` (user) | **All conversations**: the workspace's connectors (`/workspaces/:id/connectors`, from its group's menu in the agents list), which every member manages (`docs/design/workspaces.md`, 2.4) |
| `.pi/mcp.json` (project) | **Only this conversation**: one conversation's own (its Connectors page) |
| A project entry replaces a user entry of the same name | The same |
| A project entry with only `enabled: false` switches a user entry off | The same: a conversation's entry with no `url` |

A conversation's tools are its agent's tools plus its connectors' tools,
`mcp__<connector>__<tool>`.

## The entry

Paste either form on a Connectors page ("Paste from pi"), or use the fields:

```json
{ "mcpServers": {
    "linear": { "url": "https://mcp.linear.app/mcp" },
    "slack":  { "url": "https://mcp.slack.com/mcp", "oauth": { "clientId": "123.456", "clientSecret": "…" } },
    "docs":   { "url": "https://docs.example.com/mcp", "headers": { "Authorization": "Bearer …" } },
    "files":  { "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."] } } }
```

or just `{ "linear": { "url": "…" } }`.

| Field | Here |
|---|---|
| `url` | A remote server: https, or http to this machine only, in development. Outside development a person's connector may not name this machine or a private or link-local address, since Rails makes the requests from inside the server's network. A name is looked up once per request, every address it gives must be public, and the request goes to that address (`McpServer::Address`), so a name that resolves, or later rebinds, to a private address is refused too; the sign-in's discovery, registration and token requests included. The office's connectors may be private, as may a workspace's own address for one at a host the operator lists in `CONNECTORS__INTERNAL_HOSTS` (docs/office.md). |
| `command`, `args` | Instead of `url`: a program and its arguments, run on the conversation's computer (below). Not a shell string. A leading `~/` names the conversation's home folder. |
| `env` | Added to the command's environment; kept encrypted. |
| `cwd` | Where the command runs; a relative one is inside the conversation's home folder. |
| `type` | `http` or `streamable-http` with a `url`; `stdio` with a `command`. |
| `headers` | Sent with every request; kept encrypted. An `Authorization` header turns sign-in off, as in pi. |
| `oauth.clientId`, `oauth.clientSecret` | Your own app, for a service with no dynamic registration (Slack, GitHub). Its redirect URL is `<APP__URL>/connectors/callback`. |
| `oauth.scope` | Asked for when the server advertises no scopes. |
| `oauth.clientRegistration` | `auto`, `dcr` or `cimd`, all read the same way: the install sends its Client ID Metadata Document where the server reads one, and registers dynamically elsewhere. |
| `enabled` | `false` keeps the connector and its sign-in but offers no tools. |
| `description`, `timeout`, `exposure`, `toolExposure` | Accepted and not used. |

Refused, each with a plain sentence: both a `url` and a `command`, `sse`,
pi's `${VAR}` and `!command` substitutions (paste the value itself),
`oauth.authServerMetadataUrl` and `oauth.clientName`, and any other field.

## Command connectors

A `command` runs on the conversation's own computer, never in the Rails or sidecar container: in its Sprite as the guest's user,
on an SSH computer as its Unix user in the agent's folder, or in development in
its local folder. It has the conversation's files and logins, and no other
conversation can see it. The connector page says so.

On an SSH computer pi-env's daemon starts it with plain pipes over the agent's
own connection, so it reaches nothing the agent's shell cannot. It gets the
user's own environment (`PATH`, `HOME`) plus `env`; a leading `~/` and a
relative `cwd` name the agent's folder. Every conversation of the agent shares
that folder. Its tools ask a person first exactly as on any other computer.

- **One process per conversation.** A connector for all conversations runs separately in
  each conversation that uses it, started the first time that conversation needs it.
- **No computer, no tools.** A conversation whose agent has no computer switched on
  gets none of its tools; its Connectors page says why.
- **Listing tools.** "Refresh tools" runs the command on a conversation's computer:
  its own, or for a connector for all conversations, the conversation whose
  Connectors page you are on (and the conversation it was added from). The person's
  own Connectors page has no conversation, so it offers no refresh for one.
- **How it is reached.** Rails is the MCP client; `McpServer::CommandTransport`
  posts each JSON-RPC message to the sidecar (`docs/design/CONTRACT.md`),
  which keeps the process on the conversation's computer and makes the handshake.
- **Lifecycle.** Started on first use, started again on the next call after it
  dies, replaced on the next call after its entry changes, and stopped after
  10 minutes without a call (so a Sprite can sleep). Each call has 30
  seconds, after up to two minutes to wake a sleeping Sprite. A failure says
  so in one sentence, with the end of the command's stderr.
- **What the computer has.** The Sprite image (`Dockerfile.agent`) has Node and npm, so `npx`
  servers work. An SSH computer has whatever the machine has. It has no Python or `uv`, so `uvx` servers do not yet.
  No sign-in: authenticate with `env` or `args`.

## Sign-in

The `mcp` gem's OAuth client does the MCP authorization flow (2025-06-18 and
later): the 401 and its `WWW-Authenticate`, protected-resource and
authorization-server discovery, PKCE S256, `state`, `resource`, refresh
before expiry, and one retry after a 401. A server that advertises
`client_id_metadata_document_supported` gets the install's Client ID Metadata
Document, `<APP__URL>/connectors/client`, as the `client_id` and fetches it
(`Connectors::ClientsController`), so nothing is registered; any other gets a
dynamic registration, as before, and a connector keeps a registration it
already has. The document's address must be https and answer from the
internet (`docs/open-routes.md`), so development registers.
`McpServer::Authorization` keeps the registration, tokens and the sign-in in
progress on the connector, encrypted. Signing out forgets the tokens and
keeps the tool list. A connector that needs sign-in, for whatever reason,
offers none of its tools to an agent (`Agent#tools`), so the model is never
offered a call that can only fail; its settings list them greyed, with Sign
in, and signing in brings them back. The declaration budget still counts
them when making a connector core, so signing in cannot crowd out other tools.

A token about to expire is renewed before the call, and one the server turns
away (401) is refreshed once by the `mcp` gem and the call tried again. That
is all, for every connector but those whose gallery entry says
`rotating_refresh: true`: today only Slack, whose refresh token works once.
Google, GitHub and the rest keep exactly that.

A connector marked `rotating_refresh` renews through `McpServer::Renewal`,
which never holds the database while the service answers, and each of its
requests waits at most 10 seconds to connect and 10 to read. It first claims
the refresh token on the connector (a digest, never the token), then asks,
then saves the new tokens only if the connector still holds the token it
claimed, so a late answer never overwrites a newer sign-in. A call that finds
the token claimed sends no second refresh: it uses the access token while
that lasts, and once it has expired the call fails with "<name>'s sign-in is
being renewed; try again in a few seconds." An expired token is never sent.
After a 401 the gem's own refresh is replaced by this one
(`McpServer::HttpTransport`), so that refresh claims the token too. The gem
offers no public hook for that refresh, so `HttpTransport` overrides its
private `attempt_refresh`; the Gemfile pins `mcp` to the version it was read
against, and `test/models/mcp_server/http_transport_test.rb` fails by name if
an upgrade moves it.

A claimed refresh token is never sent again. If the renewal's request never
left (it could not connect, or failed before asking for the token), the
claim is let go and the next call renews. Otherwise, with no answer in time,
a cut connection or an error, nobody can know whether the service spent
the token, and we found no promise from Slack that sending it again is safe.
So the claim stays: calls go on with the access token while it lasts, and
after that each gets "<name> needs you to sign in again." and the
connector shows Sign in. Signing in again clears the claim. A claim left
by a renewal that never finished (the process stopped) counts the same
once it is two minutes old.

### Receive a client secret from someone outside

On a conversation’s Connectors page, the connector’s creator or the workspace
owner can choose **Set client secret** when an existing OAuth client ID has no
secret. Share the link only with the intended recipient. It expires in 15
minutes and works once. The recipient needs no Lanyard account. The form can
only fill that connector’s empty encrypted client secret. It does not
replace a secret, start sign-in, or give the recipient any other access.

### Connect an expected Gmail account from outside

On the conversation’s Connectors page, turn the Gmail connector off and make
sure it has a registered Google web client for the usual
`<APP__URL>/connectors/callback`. The connector’s creator or its workspace
owner can enter the expected Gmail address and choose **Create Google sign-in
link**. Share the link privately. Making a new link replaces any earlier
attempt for that connector. The visitor needs no Lanyard account, but they must
finish in the browser that starts the link, within 15 minutes of issuance.

**Text me this link** sends the same link from this agent’s saved number to
your own number on file in that workspace. It requires the workspace’s own
voip.ms account and respects your sole-contact choice. It does not use the
install’s account or ask you to verify your number. You can still copy the
link by hand.

The browser keeps the link's token out of the URL sent to the app; the first
**Continue to Google** submit claims it. The app requests only the connector’s
configured scopes and checks the new token’s actual mailbox with Google’s
[Gmail profile API](https://developers.google.com/workspace/gmail/api/reference/rest/v1/users/getProfile).
The address must match, ignoring case but not dots, plus tags or aliases.
If Google refuses, returns a different mailbox or different scopes, or if the
connector, client or issuer has changed, the app does not change the existing
grant or ordinary OAuth state. A matching grant replaces the stored grant but
leaves the connector off and does not start an app session.

The existing Calendar, Drive, Docs and Chat scopes do not request an email
through [Google UserInfo](https://developers.google.com/identity/openid-connect/reference).
Those connectors are not offered this link. This flow does not add identity
scopes or infer an account from a chooser hint. Ordinary connector sign-in is
unchanged.

#### Grant Gmail access to one agent

On that agent's **Connectors** page, add Gmail under **Only this agent** and
leave it off and unsigned in. If it uses the install's Google client and the
Gmail gallery scopes, the workspace owner can name the Gmail address and
choose **Create Gmail access link**. This uses the same one-use, 15-minute
link and mailbox check as above. The recipient sees the agent's name and what
it can do before continuing to Google. Google asks for read and compose
access, but this grant only lets the named agent search Gmail. It does not
let the agent draft or send mail, fetch attachments or copy the inbox into
its thread.

The connector turns on only after Google confirms the named account. The owner
sees the agent, Gmail address and grant time on the same page. **Revoke Gmail
access** cancels a pending link or clears a completed grant's tokens and turns
the connector off. It stops the agent's future searches, not requests already
sent. It doesn't remove the permission you gave in Google or undo earlier
reads; manage that in your [Google Account settings](https://myaccount.google.com/permissions).
A new link can grant access again to the same agent. Moving the agent to another
workspace revokes the grant and removes the mailbox address from the receipt.

Wait until web and job processes run this release before issuing agent-bound
links. Revoke them before rolling back to a version that predates this guard.

### Copy a Gmail inbox to an agent

A Gmail connector supplies the existing read-only access for the separate
**Gmail inbox** switch on an agent's **Channels**. It does not turn on
automatic delivery by itself. The workspace owner must choose the connector
and enter its Gmail address. The app checks that address against the
connector's Google profile at setup and before each poll, not against the
owner's app sign-in. This asks for no new Google scope and changes no tool
or approval setting. Turning off connector tools is independent of the inbox
switch; signing out of the connector pauses copying. See
[Gmail inbox](email.md#gmail-inbox) for what is copied and who can see it.

## The office's connectors

The office's wiki and CRM (`docs/office.md`) are connectors a workspace turns on,
listed in `config/install_connectors.yml`:

```yaml
shared:
  wiki:
    url: <%= (Rails.app.creds.option(:wiki, :url).presence || DurableAssistants.kamal_url("wiki", ":3000/mcp")).to_json %>
    api_key: <%= Rails.app.creds.option(:wiki, :api_key).to_json %>
    fetches_attachments: true          # optional: save Outline attachments to the agent's computer
    uploads_attachments: true          # optional: relay Outline's signed upload form
    tools: [ "list_*", "fetch", "get_*", "{create,update}_{document,comment}", "move_document" ]
    loaded: false                      # optional: looked up for all; true, core where it fits
```

Each is offered once its address and key are set, and the address defaults to the
office's accessory inside the host. A workspace has one only once it is turned
on, under Office connectors on its Connectors page, by the workspace's owner or
by the install's owner (`OFFICE__OWNER_EMAIL`, never its admins; unset, there
is none) if they belong to it. It is then a connector of that name, in the
workspace owner's name, on for all its agents and switched off for one as any
other is; any member switches it off, only those two switch it back on, and
nobody can change or remove it.

The install's key is its owner's: only a workspace the install's owner owns
uses it. Any other workspace needs its own key (`docs/office.md`, A workspace's
own key) before it can turn one on, so nobody else's agents reach what the
install's key reaches.

Its address may be plain http, to that host only, since it is reached inside
the install's host; a person's own connector still must be https, to a
public address. The shared key is read from settings on each MCP call, sent
as a bearer token, and never kept on the connector. `tools` are shell patterns
(`File.fnmatch`, with `{a,b}`): a refresh keeps the server's tools that match
one. `InstallConnectorsJob` keeps each turned-on connector in line every ten
minutes, and a sign-in does at once; it never makes one or switches one back
on. Without any key for it, an entry goes from every workspace. One in a
workspace that may no longer use the install's key, and has none of its own,
is switched off, never deleted, and the log says so once. A connector a
person made first under the same name keeps it.

**Outline files.** `fetches_attachments` enables downloads from the wiki's
connector address. With `uploads_attachments: true`, a refresh that finds
Outline's `create_attachment` lists the Rails-owned `upload_attachment`
instead. It follows the connector's tool switches, core/lookup rules,
tool budget and write approval policy. The raw tool is not offered.
For `mcp__wiki__upload_attachment`, pass one computer path in `attachments`;
`name` and `content_type` are optional. Use the returned URL to add the
attachment to a document. Like Gmail's file tools, it needs a direct call or
`tools.mcp__wiki__upload_attachment(...)` in a code mode script. The upload uses the connector address and the signed POST
form, without forwarding the connector's key. See [Wiki attachments](office.md#wiki-attachments).

## Core and looked up

A connector is **core** for an agent when its tools travel in every message
that agent reads, and **looked up** for it otherwise. Each agent decides for
itself, on its Tools ("Core for <agent>", `Agent::CoreConnector`): a person's
connector is looked up for every agent until made core for one, and making it
core for one changes nothing for another. Its page lists the agents it is core
for. A conversation's own connector belongs to one agent already and keeps its
own switch (`loaded`). An office connector whose entry says `loaded: true` is
core for each of the person's agents where it fits; where it does not fit, it
stays looked up there and the move is recorded, as below. `loaded: false`
makes it looked up for all of them. The word is applied when the connector is
made, when the entry changes it, and to each agent made later, not on every
run: one made by an earlier release, before connectors were core per agent,
stays as it was at deploy until the entry changes.

An agent starts with at most 59 tools, including the sidecar's own tools for
its abilities and computer (`agent/own-tools.json`). The sidecar has 64
slots, so at least five are free to load tools the model finds. The
looked-up tools go to the sidecar as `lookup`; `tool_search` itself counts
as one of the 59 when there are any.

**An agent's own rarer tools too.** Of its built-in tools only a small core
travels in every message, named in one list (`Tool::Catalog::CORE`): talking
to people on its channels (email, text, Telegram, Campfire, Concourse,
iMessage, `ask_person`), its notes, `current_time`, its canvas, `read_skill`,
its own calendar and tasks (the five CalDAV tools, used most days),
the saved sign-in tools where it has a screen.
The sidecar adds codemode, and the screen's desktop and browser tools, itself.
Every other built-in is looked up like a connector's: for example,
`campfire_rooms`, `concourse_find`, `imessage_attachment`, `change_yourself`,
the routines, `make_agent`, `pay_by_card`, `ask_outside_for_sign_in`,
`withdraw_question`, `withdraw_card` and Campfire room admin. These tools
are called by name and keep their approvals. Switching a rare tool on adds
nothing to the declaration count (#116).

**With tool_search, and from code mode.** The definition also carries the
agent's looked-up tools as `lookup` (at most 1,024, never a tool switched off or
one whose connector needs sign-in), with code mode or without. The sidecar
registers them deferred (`agent/extensions.mjs`), so the model sees none of
them at first. It offers pi's `tool_search` over them: the model searches, and
the tools it finds are its own from its next step, called by name with typed
inputs (`agent/tool-search.mjs`; a load counts toward the 64). A code mode
script finds them with `searchTools()` and calls one as `tools.<name>(...)`.
Rails resolves that name to the same tool it would declare, so the inputs,
approvals, "asks every time", switches and ledger are the same. A loaded tool
stays loaded for the conversation, through a change to the agent.

The same allow-lists apply: `tools` in the install's file still decides what
there is to find. The search is pi's, the same for every model.

**A refresh that no longer fits.** Making a connector core checks that agent's
count only, never another's. If a refresh would take an agent past 59,
the refresh still succeeds. The connector becomes looked up for that
agent only. The move is recorded (`Agent::ConnectorMove`: the agent, the
connector, when and why). The agent's Tools list it under
"Looked up", and its instructions gain one line naming the connector and how to
reach its tools now, until it is core again or gone. It cannot be made core
again until it fits. Another agent it is core for keeps it.

**Overflow stays reachable.** A deploy can add tools without saving the
connector. If the declaration would go past 59, `Agent#tools` puts the last
core tools, by connector name, in lookup instead. The same tools move each
message. Saving the agent itself is never refused for its count. Its Tools
meter shows what it wants to carry before this overflow is moved.

## Ask before every write

A connector's page has a switch, off by default, called **Ask before every
write**. It is for an account that acts as its owner, such as a chat account
that posts in their name. When it is on, every tool of that connector that the
server doesn't mark read-only (`annotations.readOnlyHint`) asks the person
every time:

- even where the install approves everything (`APP__APPROVE_EVERYTHING`) or
  allows everything (`APP__APPROVALS=allow`);
- with no "Always" on its card, and an "Always" given before no longer counts.
  Permissions keeps the old "Always", marked as not used, so switching the
  connector back restores it.

Read-only tools still run at once. A tool switched off, on the connector or
for one agent, stays off. The card says which connector the call acts as
("Allow post message as chat?"). Permissions lists these tools among those
that still ask every time. The switch is the `mcp_servers.asks_every_write`
column, so an operator can turn it on for one connector without a deploy. A
conversation's own connector is a record of its own, with its own switch.

### Gmail replies without asking

A workspace owner can open a Gmail connector and allow replies to one address
per agent. This is the one exception to **Ask before every write** and Gmail's
every-time approval for `send_message`. It applies only when the address is the
sole recipient across To, Cc and Bcc, is not hidden in Bcc alone, and Gmail
confirms it is already in the thread. The app checks the thread on the
connector the agent uses. If it can't verify the reply, the call still gets an
approval card. New messages, drafts and other writes are unchanged.

The conversation shows which address the agent used the grant for. Use
**Revoke** on the connector page to stop future use, including replies still
waiting for the check. Signing out also removes the connector's reply grants.

## The gallery and the instance's own apps

`config/connectors.yml` lists services a person can add in one click. An
entry's address, scope and app come from the file, never from the form.

An entry may name one of this instance's own OAuth apps (`app: google`). Its client ID and secret are settings,
`CONNECTORS__GOOGLE__CLIENT_ID` and `CONNECTORS__GOOGLE__CLIENT_SECRET`
(`connectors.google__client_id` and `connectors.google__client_secret` in
credentials). The connector keeps only the app's name; the secret is read
from settings at each sign-in, and goes only to the server the gallery entry
names. "Your own app's client ID" on the entry overrides it for that
connector. Without the instance app, the entry asks for a client ID.

An entry marked `vault: true` (Clio Manage, Slack) takes its app from the
password manager instead: the person names an entry holding the app's client
ID as its username and secret as its password, saved for the entry's
`vault_host` (where the secret is sent). Both are read from there, as the
agent or the workspace and on the workspace's own server if it has one, at
each sign-in and renewal, and never kept or logged (see "Clio Manage"
below). It is offered only where the vault is set up; Slack, marked
`own_client` too, asks for a pasted app where it is not. The secret goes
only to `https://` and that host: a service whose sign-in metadata names a
token address anywhere else is refused before anything is sent
(`McpServer::VaultClient::TokenAddress`), at sign-in and at every renewal.
Clio's token address is fixed, never taken from metadata.

An entry stays offered once added: a second account of the same service
(a work Gmail beside a personal one) is "Add another", under a name of its
own (`gmail_work`; it suggests a free one, `gmail_2`), since a name is a
connector's key and its tools' prefix. Each signs in on its own, and
Connectors shows each as its service, the second with its name ("Gmail ·
gmail_work"); a connector is known as a gallery service by its address.

**Google** (Gmail, Calendar, Drive, Docs, Chat) offers no dynamic registration, so
it needs the instance app or the person's own. Make a "Web application"
OAuth client in a Google Cloud project with the MCP services enabled
(`gmailmcp.googleapis.com` and the rest), with the redirect URI
`<APP__URL>/connectors/callback`. Each entry asks for its own scopes, from
Google's guides. Google gives a refresh token only to a sign-in that asks
for `access_type=offline` and `prompt=consent`; Rails adds both to any
sign-in at `accounts.google.com`, with `select_account` so a second account
can be chosen. Google's servers name their authorization
server in their protected-resource metadata, so no `authServerMetadataUrl`
is needed. An app in Google's Testing mode ends each sign-in after 7 days:
the connector then says it needs sign-in.

**Gmail, Google Calendar, Google Drive and Google Chat run on Google's plain
APIs.** Google's hosted MCP servers answer only projects enrolled in its
Developer Preview, so a connector at `gmailmcp.googleapis.com`,
`calendarmcp.googleapis.com`, `drivemcp.googleapis.com` or
`chatmcp.googleapis.com` signs in there as above, but Rails answers its tools
itself (`McpServer::Google`), calling the Gmail, Calendar, Drive, Docs and Chat
REST APIs with the same token. The project needs `gmail.googleapis.com`,
`calendar-json.googleapis.com`, `drive.googleapis.com`, `docs.googleapis.com`
and `chat.googleapis.com` switched on; no enrolment, and no "AI-powered agent"
flag on the client. Gmail's and Calendar's tools keep
the hosted servers' names:

- **Gmail:** `search_threads`, `get_thread`, `get_message`, `get_attachment`,
  `list_labels`, `list_drafts`, `get_draft` (read, so they run at once); `create_draft`,
  `update_draft`, `send_draft`, `send_message`, `delete_draft` (each asks the
  person, unless the install approves everything; sending and deleting a
  draft ask every time, even then, and are never "Always"). `send_message`
  is sent once: one Gmail takes and never answers is looked for in its Sent
  by the Message-ID the app gave it, never sent again (docs/email.md, "When
  the mail server doesn't answer"). New and updated drafts and messages carry
  the agent's plain text and an HTML alternative with its paragraphs and line
  breaks. `send_draft` sends the stored draft as it stands. Labelling and the
  trash need `gmail.modify`, which the gallery doesn't ask for, so they aren't offered.
  `get_thread` always answers whole JSON under 40,000 bytes: every message's
  id, sender, date and size, and each message in full while it fits. Past
  that it says `truncated: true`, and the rest carry a note to read them with
  `get_message`.
  A message read whole (`get_thread`, `get_message`) has its from, to, cc,
  reply_to, subject and date; a header the message lacks is left out.
  A message's text is its `text/plain` part where it has one, else what its
  HTML shows a reader: no head, styles, scripts or templates, and a line
  break where a line, paragraph, list item, row or heading ends. Every
  message, in `get_thread` and `get_message`, says its text's whole length
  in characters (`text_length`), and comes 20,000 characters at a time.
  A text cut there says `truncated: true`, where to read on (`next_offset`)
  and, in a `note`, how: `get_message` with its `text_offset` gives the next
  20,000 characters, so a long message reads whole, chunk after chunk.
  `send_message` and `create_draft` take files from the agent's computer
  (`attachments`), as `send_email` does (docs/email.md): the same limits, the
  card naming each file and its size, the approval held to their bytes, and
  a missing file refused by its name, with nothing sent or saved.
- **Calendar:** `list_calendars`, `list_events`, `get_event` (read);
  `create_event`, `update_event`, `respond_to_event`, `delete_event` (ask;
  deleting asks every time, even where the install approves everything, and
  so does an event that reaches other people: a new one with a guest who
  isn't one of the person's own addresses (their sign-in's and the
  connector's account), or an update that names guests or emails them).
  Guests are emailed only when `send_updates` says so. A new event with
  guests gets its own Google Meet link and lets guests change it; `meet: false`
  and `guests_can_modify: false` turn those off. An update adds a link only
  with `meet: true`, and never replaces one the event has. The answer gives
  the link as `hangout_link`.
- **Drive and Docs**, one connector: `search_files`, `read_file` (a Doc as
  Markdown or text, a Sheet's first sheet as CSV, Slides as text, a text file
  as it is, any other file saved as below), `list_permissions` (read); `create_document`, `edit_document`
  (the Docs API's own edits, `documents.batchUpdate`), `share_file` (ask,
  unless the install approves everything; a share outside the Google account's
  own domain, or to anyone with the link, asks every time, even then). The
  account's domain counts as its own only when it is an organisation's: an
  account at gmail.com shares outside with anyone but itself and the person's
  sign-in address. There is no tool to delete. The gallery offers it twice,
  by what it asks for:
  - **Google Drive and Docs** (`drive.file` and `drive.readonly`): reads every
    file, but makes, edits and shares only the files it made (Google's Docs
    API takes `drive.file` for `documents.create` and `documents.batchUpdate`).
  - **Google Drive and Docs, every file** (`drive` and `documents`): edits and
    shares any of them.

  A connector added from the old Google Docs entry still talks to Google's
  hosted Docs server; add Google Drive and Docs in its place.
- **Chat** (`chat.spaces`, `chat.messages`): `list_spaces` (spaces, group
  chats and direct messages, with their last activity), `list_messages` (one
  space, newest first, between two times or in one thread), `get_message`
  (read); `send_message` (text, as the person, into a space or one of its
  threads, a new thread if Google can't reply there) and `react` (one unicode
  emoji on a message), which ask every time, even where the install approves
  everything, and are never "Always". No editing or deleting. A connector
  added when the gallery asked only to read (`chat.spaces.readonly`,
  `chat.messages.readonly`) keeps reading and isn't offered the two (its
  sign-in keeps the scope it was added with): remove it and add it again to
  post. A sender shows by name where Google gives
  one to a person's sign-in (a member of the space, or someone they have
  talked with), otherwise by their `users/` id. Google offers a person no
  search of messages across spaces, so there is none. Chat needs a Google
  Workspace account. Reading needs only the API switched on and the client;
  posting and reacting also need the Chat API configured in the project (an
  app name, avatar and description), and Chat shows that app's name beside a
  message posted this way.

**Several accounts of one kind.** Two or more Google connectors of one kind
(two Gmail accounts, say) give an agent one set of that kind's tools, named
`mcp__<kind>__<tool>` (`mcp__gmail__search_threads`), each with an optional
`account` argument: the connector's name, the first that offers the tool by
name when left out. The tool description names the available accounts, so
they also appear in `tool_search` results.
The connectors don't change. Each keeps its own sign-in, scope and switches,
and a call runs with the chosen connector's token. A tool is in the set when
any of them offers it; naming an account that has it switched off is an
error that names the account, and a scope Google refuses comes back with
Google's own message and the connector's name. The approval card says which
account, "asks every time" and "own domain" are judged on that account, and
"Always" is granted as that connector's own tool (`mcp__<connector>__<tool>`),
so it never covers the other account. The set is core for an agent when any
of its connectors is. One connector of a kind keeps its own names.

The connector's token is renewed at Google's token endpoint with its client
when it is about to expire, and once more if Google turns it away; a sign-in
Google won't renew makes the connector need sign-in.


### Results over the limit

A connector's answer longer than the sidecar keeps of one result is not
lost (`Tool::Mcp::LongAnswer`). "Longer" is counted the way the sidecar
cuts: the answer's bytes as JSON in UTF-8, over 45,952
(`DurableAssistants::ResultBytes::ANSWER`, the sidecar's limit of 49,152
less room for what it adds), never characters, so a text in a script of
three bytes a character is caught well under 50,000 characters. On a Sprite, the whole
answer (its text, or its structured content as JSON) is saved on the
agent's computer, as `~/files/<folder>/<tool>-answer.txt` (or `.json`), the
way a Gmail attachment is (below), and the model reads as much of its start
as fits (`Tool::Mcp::SHOWN_BYTES`), the saved path, and a note that the rest
is there (listed in `found_files`, beside any files the answer carried). Between the call and the sidecar's fetch the whole text waits in
Active Storage, attached to the call (`Invocation#held_files`), not in the
ledger the page shows; it is
purged ten minutes after the call (`InvocationFilePurgeJob`), when the
sidecar may no longer fetch it, and no link to it is served to anyone
(`ReachableBlobs`). Without a Sprite there is nowhere to put the rest: the
answer is cut to the start that fits, and the note says why.

An answer still over the sidecar's limit on one result (49,152 bytes or
2,000 lines) is saved whole on the agent's computer by the sidecar, and the
model or the script gets valid JSON with its path, its size and its start,
never a cut copy (`agent/whole-results.mjs`; docs/agent.md, "One size
limit for every result").

### Pictures in a connector's answer

MCP image blocks reach the model as pictures, including from a script. The same limits as attached pictures apply: up to four PNG, JPEG,
WebP or GIF images, no more than 5 MiB each. The connector's whole reply,
including base64 and JSON, is capped at 16 MiB. In a text answer, images
that cannot be included and other binary blocks are named, not inlined.
Images do not count toward the text limit or appear as base64 in the tool card.

### Files in any connector's answer

A connector may answer with files: MCP's embedded resources with their
bytes (`{type: "resource", resource: {uri, mimeType, blob}}`, base64) or
links to them (`{type: "resource_link", uri, name, mimeType}`). The app
saves every one on the agent's computer as it does a Gmail attachment
(`Tool::Mcp::FoundFile`). Each is listed in the answer's `found_files` and
fetched by its place there (`POST /agent/files` with `index`); the sidecar
saves each under its own name in the call's folder (`a.zip`, then
`a (2).zip`), and the model reads each one's name, type, size and saved
path, and for a PDF the path of its words (`full_text`). A long answer that
carries files gets both: the files, and the whole answer as one more file.
A file that fails says why; the others are kept.

- **Embedded bytes** wait on the call in Active Storage
  (`Invocation#held_files`), like a long answer, and go after ten minutes.
- **A link** is fetched by Rails when the sidecar asks, and only from the
  connector's own origin: the same scheme, host and port as its address,
  with its own headers, pasted key or sign-in token, no redirect followed,
  and outside development pinned to a public address (`McpServer::Address`).
  A link anywhere else is refused before any request, and the answer says so
  (`McpServer::LinkedFile`): a server writes its own links, and could
  otherwise aim this app, and the connector's credentials, at anything the
  app can reach. The office wiki's attachments keep their own route
  (`McpServer::WikiAttachment`): the wiki links them on its public name,
  which is not the connector's address, so they are not a case of this one.
- **Without a Sprite** the files are listed in `not_saved`, and the note
  says why.

### Files and PDFs

`get_attachment` (an email's attachment, by the `attachment_id` that
`get_thread` and `get_message` list) and `read_file` on a PDF save the file on
the agent's computer, in `~/files/<folder>/<name>`, where its shell can open
it. The tool says where, with the file's name, type and size; Gmail's read
scope is enough, and nothing is asked for again.

`read_file` saves a text whole the same way when it is too long to read into
the answer: a Doc, Sheet or Slides export, or a text file, over 40,000 bytes
as JSON (`Drive::READ_BYTES`, counted as the sidecar counts, so non-ASCII
text is caught too) comes back as the start that fits and the path of the
whole, saved as `<name>.md`, `.csv` or `.txt`; a text file over 5 MB
(`Drive::DOWNLOAD_LIMIT`) is not read into the answer at all, only saved.
Without a Sprite the start still comes back, and the note says the rest was
not saved.

Every other file `read_file` finds is saved too, whatever its type; it never
answers with only a description. A Word, Excel or PowerPoint file (`.docx`,
`.xlsx`, `.pptx`, up to `Drive::DOWNLOAD_LIMIT`) also comes back as its words,
read from the XML inside it (`DurableAssistants::OfficeText`): a document's
paragraphs, the first sheet as tab-separated rows, each slide's paragraphs,
with no formatting, and cut at `Drive::READ_BYTES` like any text. A Google
Doc, Sheet or Slides asked for with `format: "docx"`, `"xlsx"`, `"pptx"` or
`"pdf"` is exported as that file and saved, a PDF's words read as above.

- **How.** The tool's answer names the file; the sidecar then asks Rails for
  its bytes (`POST /agent/files`, inside the host only, within ten minutes of
  the call), and Rails fetches them from Google with the connector's own
  sign-in. The bytes are written to the computer and kept nowhere else: not
  in the ledger, the model's context, or Rails' storage. A Drive file (like
  the wiki's and BlueBubbles') goes through a temporary file in Rails,
  streamed to the sidecar and deleted once sent; a Gmail attachment comes
  from Google as base64 JSON, so Rails holds that one whole.
- **Any size.** Nothing refuses a file for being big. The sidecar writes it
  to the computer a few MiB at a time under a hidden `.<name>.<random>.partial`
  beside it, then moves it into place, so a half-written file never has the
  file's name; a failure removes the partial file. It gives up only when no
  bytes arrive for a minute (`FILE_IDLE_MS` in `agent/server.mjs`), never
  after a fixed total time. When Rails says the file's length, the sidecar
  first checks the computer's free space (`df`), and refuses a file that
  won't fit, saying how many MB it needs and how many are free.
- **A PDF's words** are read on the computer, by `agent/guest/pdf-text.mjs`
  with poppler's `pdftotext -layout`, each page under `--- page N ---`. A page
  with no text layer, a scan, is drawn at 200 dpi and read by tesseract
  (English). The first 30 pages, up to 60,000 characters, come back with the
  call, marked as information, not instructions; the whole text is saved
  beside the file as `<name>.txt`.
- **Names.** A name keeps no folders, control characters or leading dots,
  and at most 120 characters. Nothing on the computer reaches the network for
  this; Rails reaches only Google.
- **Where.** Only on a Sprite: the computer image carries poppler and
  tesseract. On an SSH or local computer the tool says what the file is and
  saves nothing.
- **When reading fails** the note says how, never just that it failed: the
  command that failed and its exit code, signal or spawn error, and the end
  of what the reader wrote to stderr. A computer made from an image older
  than the reader says it must be made again (`docs/deployments.md`). A
  Sprite keeps the image it was made from, and making it again deletes its
  disk, `/home/agent` included: copy out what it holds first.
  `bin/check-pdf-reader <image>` runs the shipped reader on a text PDF, a
  scanned page and a broken file; CI runs it on each computer image before
  publishing it, and `agent/test/pdf-reader-image.test.mjs` drives the
  sidecar's half through the image's real pi-env when `PDF_READER_IMAGE` names
  an image.
## IMAP, headers only

The gallery's **IMAP (headers only)** reads any mailbox that speaks IMAP over
TLS, one connector per mailbox, without a sign-in page: the person gives the
mail server, port (993 unless told), username and password (an app password
where the provider offers one). Rails answers it, as it does Google's
(`McpServer::Imap`): the address is kept as `imaps://<username>@<host>:<port>`
and the password as the connector's encrypted token. No migration.

- `list_mailboxes`: each folder that can be opened, with how many messages
  it holds.
- `search_headers(mailbox, from?, to?, subject?, since?, before?, limit?)`:
  newest first, at most 50, each with its uid, from, to, cc, subject, date
  and message id, and reply_to where replies go to someone other than the
  sender (a server reports the sender there when a message names no
  Reply-To). Marked as information, not instructions.

Both read, so they run at once. **Read-only by construction**: a folder is
opened with `EXAMINE`, never `SELECT`, and only `ENVELOPE` is fetched, so no
message is marked read and no body or attachment is fetched. Nothing sends
`STORE`, `COPY`, `MOVE`, `APPEND` or `EXPUNGE`; the tests run against a fake
server that fails on any of them. TLS only, with the certificate and name
checked; 15 seconds to connect, and 30 for a whole call, which signs in and
out. Outside development, the server's name must resolve to a public
address, and the connection goes to that address (`McpServer::Address`). A
refresh signs in once, so a wrong password shows on the connector.

## X

The gallery's **X** reads and posts as one X account through X's API v2
(`https://api.x.com/2`), answered in Rails (`McpServer::X`). There is no
sign-in page: X's developer console gives the account's owner four values
for their own app (API key and secret, access token and secret, with read
and write access), and the form takes all four. They are kept together, as
JSON, in the connector's encrypted token. No migration, and no gem: requests
are signed with OAuth 1.0a HMAC-SHA1, and the tests check the signing
against X's published example.

- `get_me`: the account's id, username and name.
- `mentions(since_id?, max_results?)`: posts that mention the account, 5 to
  100 (10 unless asked), each with its author's username, and a `newest_id`
  to pass as `since_id` next time.
- `search_recent(query, since_id?, max_results?)`: the last seven days, 10
  to 100. `conversation_id:<id>` finds the replies in a thread.
- `get_post(ids)`: up to 100 posts, with their public counts.
- `create_post(text, reply_to?, quote_post_id?)`: a post, reply or quote.
  Quoting needs an X plan that allows it.

The reads run at once and their results are marked as information, not
instructions. `create_post` asks every time, offers no Always, and asks even
where the install approves everything. There is no tool to delete a post,
and nothing polls: X charges per call, and a call is made only when the
agent makes one. When X refuses, the agent sees its status and title, and
for a rate limit when it resets: a 402 is a spending cap, a 429 a limit.

## Clio Manage

The gallery's **Clio Manage** reads a Clio account through Clio's API v4
(`https://app.clio.com/api/v4`), answered in Rails (`McpServer::Clio`,
`DurableAssistants::Clio`). Only Clio's US region for now: each region is its
own host, which is one constant (`DurableAssistants::Clio::HOST`). It is
offered only where the password manager is set up.

Setting it up:

1. In Clio's developer portal, make an app for the account, with the
   redirect URI `<APP__URL>/connectors/callback` and access to matters,
   contacts, custom fields, documents and calendars.
2. Save its client ID and secret in the password manager as one entry for
   `https://app.clio.com`: the client ID as the username, the secret as the
   password. Share it with the workspace's vault user, or the install's.
3. Add Clio Manage from the gallery, naming that entry, and press Connect
   Clio. Clio asks you to let the app in, then sends you back here.
   Finish within ten minutes of starting the sign-in. The link works only once;
   if it expires or you started before this limit was added, press Connect again.

The connector keeps only the entry's name (`vault_entry`). The client ID and
secret are read from the vault for each sign-in and each renewal, as the
workspace's vault user (or, for one conversation's own connector, its
agent's), and are never kept or shown. An entry saved for another site is
not sent to Clio. The entry is the app's, never an agent's: no saved-sign-in
tool lists, fills or uses it (`Agent#reserved_sign_in?`). The sign-in, an
access token and a refresh token, is kept on the connector, encrypted, like
any connector's; it is renewed before it expires and once more if Clio turns
a token away. If Clio refuses to renew it, the tokens are forgotten and the
connector says it needs a sign-in. The callback's `state` is made for this
connector, found only in the workspace whose person started it, and used
once.

- `search_matters(query?, status?, client_id?)` and `get_matter(matter_id)`,
  with its custom field values.
- `search_contacts(query?, type?)` and `get_contact(contact_id)`.
- `list_custom_fields(parent_type?)`.
- `search_documents(query?, matter_id?)` and `get_document(document_id)`: a
  document's name, type, size, matter and folder. Its contents are not
  downloaded: that would need the file-saving path Google's files use, and
  waits for a real need.
- `list_calendars` and `list_calendar_entries(from, to, calendar_id?,
  matter_id?, query?)`, each repeat as its own entry.
- `create_calendar_entry(calendar_id, summary, start_at, end_at, all_day?,
  description?, location?, matter_id?)`.

Lists come a page at a time (`limit`, 25 unless asked, up to 200), in id
order, with a `next_page_token` to pass back with the same filters. Clio
answers only the fields asked for, so each tool names its own
(`McpServer::Clio::FIELDS`). The reads run at once and their results are
marked as information, not instructions. `create_calendar_entry` asks every
time, offers no Always, and asks even where the install approves everything.
As with every connector, an agent reaches its tools as
`mcp__<connector name>__<tool>`, so `mcp__clio__search_matters`.

## Status

Each connector shows where it stands, as pi's `/mcp` does, with one fix:

| State | Means | Fix |
|---|---|---|
| Connected | Its tools are listed and its sign-in works. | |
| Listing its tools… | The first list is on its way. | |
| Needs sign-in | The service refused us: never signed in, signed out, or its sign-in ended (a refresh token rejected; Google's Testing mode ends one after 7 days). The rejected tokens are forgotten, and its tools are offered to no agent until it signs in. | Sign in again |
| Failing | The last refresh or call failed for another reason, said in one sentence. | Retry |
| Off | `enabled: false`. | Turn on |
| No computer | A command connector on a conversation with no computer switched on. | The agent's settings |

A call that succeeds clears a failure. A tool's own error is its answer,
not a broken connector. A conversation's header says "Connectors · 1 needs you"
while a connector it uses needs sign-in or is failing, and both pages follow
changes live. A call refused for sign-in tells the model to ask the person to
sign in again rather than retry. Rails holds all of this: it is the MCP client
(`McpServer#status`), and the sidecar never sees a connector.

## When a change applies

Rails sends the agent's whole definition, tools included, with every message,
and nothing caches the tool list between messages. Adding, switching off or
removing a connector applies from the conversation's next message, with no restart,
like pi's "a running session uses the new credentials on its next turn".
Within a run already going, a removed tool stops at once (the ledger looks
the tool up when it is called and refuses one the conversation no longer has); a new
tool waits for the next message. A command connector's process is kept under
a digest of its entry, so a changed entry restarts it on its next call.
