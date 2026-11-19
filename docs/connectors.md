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
or in development in its local folder. It has the conversation's files and logins,
and no other conversation can see it. The connector page says so.

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
  servers work. It has no Python or `uv`, so `uvx` servers do not yet.
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
in, and signing in brings them back. The 64-tool limit still counts them, so
signing in never takes an agent past it.

## The office's connectors

The office's wiki and CRM (`docs/office.md`) are connectors a workspace turns on,
listed in `config/install_connectors.yml`:

```yaml
shared:
  wiki:
    url: <%= (Rails.app.creds.option(:wiki, :url).presence || DurableAssistants.kamal_url("wiki", ":3000/mcp")).to_json %>
    api_key: <%= Rails.app.creds.option(:wiki, :api_key).to_json %>
    tools: [ "list_*", "fetch", "get_*", "{create,update}_{document,comment}", "move_document", "create_attachment" ]
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

Its address may be plain http, to that host
only, since it is reached inside the install's host; a person's own connector
still must be https, to a public address. Its key is read from settings on
each call, sent as a bearer token, and never kept on the connector.
`tools` are shell patterns (`File.fnmatch`, with `{a,b}`): a refresh keeps only
the tools that match one, which states what agents may do and keeps them
within the 64 tools the sidecar takes. `InstallConnectorsJob` keeps each one
turned on in line every ten minutes, and a sign-in does at once; it never makes
one, nor switches one back on. Without any key for it, an entry goes from every
workspace. One in a workspace that may no longer use the install's key, and has
none of its own, is switched off, never deleted, and the log says so once. A
connector a person made first under the same name keeps it.

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

The sidecar takes 64 tools in all. In place of every looked-up connector the
agent gets two tools, two in all however many it has:

- `find_tools(query, connector?)` searches those connectors' kept tool lists by
  name and description and returns the best five with their full inputs. Its own
  description names each connector and its first tools, so the agent knows what
  it can look for.
- `use_tool(name, arguments)` calls one. Its arguments are checked against the
  tool's own schema, it asks the person first unless the server marks it
  read-only, and it runs through the same ledger and `McpServer#call_tool` as a
  core tool. The approval card names the tool it calls.

**An agent's own rarer tools too.** Of its built-in tools only a small core
travels in every message, named in one list (`Tool::Catalog::CORE`): talking
to people on its channels (email, text, Telegram, Campfire, Concourse,
iMessage, `ask_person`), its notes, `current_time`, its canvas, `read_skill`,
its own calendar and tasks (the five CalDAV tools, used most days),
the saved sign-in tools where it has a screen, and `find_tools` and `use_tool`.
The sidecar adds codemode, and the screen's desktop and browser tools, itself.
Every other built-in, such as `change_yourself`, the routines, `make_agent`,
`pay_by_card`, `ask_outside_for_sign_in`, `withdraw_question`, `withdraw_card` and Campfire room admin, is looked up like a connector's: `find_tools` names them and finds
them, `use_tool` or a script's `tools.<name>` calls them. Through `use_tool`
a built-in reads the call as if it were made directly: its own name and
arguments (`Tool#arguments`, `Invocation#call_arguments`) on the ledger's own
row, so it asks whom and when it would (`Tool.asks`, "every time", "even
approving everything", one approver), its records point at the call that made
them, and a payment or saved sign-in still
reaches the browser afterwards. Switching a rare tool on adds nothing to the
count (#116).

**From code mode too.** Where the agent has code mode (on for every new agent
where the install offers it; an existing agent keeps its settings), the
definition also carries its looked-up tools as `lookup` (at most 1,024, never a
tool switched off or one whose connector needs sign-in). The sidecar registers
them deferred and callable only from a script (`agent/extensions.mjs`), so a
script finds them with `searchTools()` and calls one as `tools.<name>(...)`,
while the model never sees them. Rails resolves that name to the same
`Tool::Mcp` `use_tool` reaches, so the inputs, approvals, "asks every time",
switches and ledger are the same. `find_tools` and its result say both routes.

The same allow-lists apply: `tools` in the install's file still decides what
there is to find. The search is plain word matching, the same for every model.

**A refresh that no longer fits.** Making a connector core checks that agent's
count only, never another's. A refresh that would take an agent past 64 no
longer fails: for each agent it would take past, and that agent only, the
connector becomes looked up, and the move is recorded (`Agent::ConnectorMove`:
the agent, the connector, when and why). The agent's Tools list it under
"Looked up", and its instructions gain one line naming the connector and how to
reach its tools now, until it is core again or gone. It cannot be made core
again until it fits. Another agent it is core for keeps it.

**Never past 64, and never refused.** Saving a connector checks the count, but a deploy that
adds tools to a connector saves nothing, and a definition of more than 64
makes the sidecar refuse every message (`tool_limit`, with the count). So
`Agent#tools` never declares more: past the limit, the last core tools, by
connector name, are looked up through `find_tools` and `use_tool` instead,
the same ones every message. Saving the agent itself is never refused for its
count. The agent's settings meter still counts what it wants. The sidecar's
own tools (desktop, `browser_upload`, `visit_website`, codemode) are not in
the 64: it counts only those Rails declares.

**Found tools stay found, unless asked.** A tool the agent calls through
`use_tool` is not made its own: nothing joins its tools without the person
choosing it. The way to keep one is to make its connector core. Where the
person switches on "Keep tools it finds" (`Agent#promotes_found_tools`, off
by default; on at deploy for an agent that had already kept one, so nothing it
declares changes), a tool the agent calls through `use_tool` is
**activated** on the conversation, as pi's `tool_search` makes a match one of
its tools (pi's docs/mcp.md, "Control tool exposure"). Only what it calls: a
search for reading also matches the tools that write, and declaring those would
widen what the agent reaches for. From the person's next message the tool is
declared as itself, `mcp__<connector>__<tool>`, with the same approval rules,
and `use_tool` no longer offers it, so the model calls it directly with typed
inputs. `find_tools` says so in its result, and lists a match that is already
the agent's own under `already_yours`. Not from the next step of the same
turn: Rails sends a definition with each message, and the sidecar fixes it
for the turn. A `use_tool` call made before its tool was declared still runs.

- **Kept for the thread.** An agent made with "New agent from here" starts
  with none: its tools are a new agent's.
- **Bounded.** Activated tools fill the room under 64 left by everything
  else. Past that, the least recently used, by calling, drop out and
  `use_tool` offers them again.
- **Cache.** They are declared in name order, so using one changes nothing.
  Only a change to the set makes a new definition. That costs a definition
  install in the sidecar (one in-memory extension and one stored record). On
  a model that takes tool changes mid-conversation (Claude 5) the change is
  appended and the prompt cache holds; on any other, the tool list heads the
  prompt, so the cache starts again from the next turn. pi pays the same.

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

An entry marked `vault: true` (Clio Manage) takes its app from the password
manager instead: the person names an entry holding the app's client ID and
secret, which are read from there at each sign-in and renewal and never kept
(see "Clio Manage" below). It is offered only where the vault is set up.

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
  the mail server doesn't answer"). Labelling and the trash
  need `gmail.modify`, which the gallery doesn't ask for, so they aren't offered.
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
  a missing file refused by its name, with nothing sent or saved. Called
  through `use_tool`, their files can't arrive, so such a call is refused
  before anyone is asked, and the agent is told to call it from a code mode
  script as `tools.<name>(...)`, where the files do arrive, or to ask the person
  to make the connector core. Only where the agent keeps tools it finds does the
  tool become its own from the next message.
- **Calendar:** `list_calendars`, `list_events`, `get_event` (read);
  `create_event`, `update_event`, `respond_to_event`, `delete_event` (ask;
  deleting asks every time, even where the install approves everything, and
  so does an event that reaches other people: a new one with a guest who
  isn't one of the person's own addresses (their sign-in's and the
  connector's account), or an update that names guests or emails them).
  Guests are emailed only when `send_updates` says so.
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
`account` argument: the connector's name, the first by name when left out.
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
