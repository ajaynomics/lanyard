# Connectors

A connector is an MCP server whose tools a person's conversations use: a remote one
at a `url`, or a `command` that runs on each conversation's own computer. The
contract is pi's own `mcp.json` server entry, so an entry that works in pi
works here, within the limits below. Pi's documentation:
[Configure servers](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md#configure-servers) and
[Authenticate with OAuth](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/mcp.md#authenticate-with-oauth).

## Levels

| pi | durable-assistants |
|---|---|
| `~/.pi/agent/mcp.json` (user) | **All my conversations**: the person's connectors (`/connectors`) |
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
| `url` | A remote server: https, or http to this machine only, in development. Outside development a person's connector may not name this machine or a private or link-local address, since Rails makes the requests from inside the server's network. A name is looked up once per request, every address it gives must be public, and the request goes to that address (`McpServer::Address`), so a name that resolves, or later rebinds, to a private address is refused too; the sign-in's discovery, registration and token requests included. The office's connectors may be private. |
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

The office's wiki and CRM (`docs/office.md`) are connectors every person has,
listed in `config/install_connectors.yml`:

```yaml
shared:
  wiki:
    url: <%= (Rails.app.creds.option(:wiki, :url).presence || DurableAssistants.kamal_url("wiki", ":3000/mcp")).to_json %>
    api_key: <%= Rails.app.creds.option(:wiki, :api_key).to_json %>
    tools: [ "list_*", "fetch", "get_*", "{create,update}_{document,comment}", "move_document", "create_attachment" ]
    loaded: false                      # optional: found when needed
```

Each is on once its address and key are set, and the address defaults to the
office's accessory inside the host. Every person has each as a connector of
that name, on for all their agents and switched off for one as any other is;
they cannot change or remove it. Its address may be plain http, to that host
only, since it is reached inside the install's host; a person's own connector
still must be https, to a public address. Its key is read from settings on
each call, sent as a bearer token, and never kept on the connector.
`tools` are shell patterns (`File.fnmatch`, with `{a,b}`): a refresh keeps only
the tools that match one, which states what agents may do and keeps them
within the 64 tools the sidecar takes. `InstallConnectorsJob` brings everyone
in line every ten minutes, and a sign-in does at once; without its key, an
entry goes from everyone. A connector a person made first under the same name
keeps it.

## Found when needed

Every loaded connector's tools travel in every request, and the sidecar takes
64 in all. A connector that isn't loaded (`loaded` off, its "Find tools when
needed" button) leaves the request. In its place the agent gets two tools, two
in all however many such connectors it has:

- `find_tools(query, connector?)` searches those connectors' kept tool lists by
  name and description and returns the best five with their full inputs. Its own
  description names each connector and its first tools, so the agent knows what
  it can look for.
- `use_tool(name, arguments)` calls one. Its arguments are checked against the
  tool's own schema, it asks the person first unless the server marks it
  read-only, and it runs through the same ledger and `McpServer#call_tool` as a
  loaded tool. The approval card names the tool it calls.

The same allow-lists apply: `tools` in the install's file still decides what
there is to find. A refresh that would take an agent past 64 no longer fails:
the connector stays found when needed, and cannot be loaded until it fits.
The search is plain word matching, the same for every model.

A found tool the agent **calls** through `use_tool` is **activated** on the
conversation, as pi's `tool_search` makes a match one of its tools (pi's
docs/mcp.md, "Control tool exposure"). Only what it calls: a search for
reading also matches the tools that write, and declaring those would widen
what the agent reaches for. From the person's next message the tool is
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
  draft ask every time, even then, and are never "Always"). Labelling and the trash
  need `gmail.modify`, which the gallery doesn't ask for, so they aren't offered.
- **Calendar:** `list_calendars`, `list_events`, `get_event` (read);
  `create_event`, `update_event`, `respond_to_event`, `delete_event` (ask;
  deleting asks every time, even where the install approves everything, and
  so does an event that reaches other people: a new one with a guest who
  isn't one of the person's own addresses (their sign-in's and the
  connector's account), or an update that names guests or emails them).
  Guests are emailed only when `send_updates` says so.
- **Drive and Docs**, one connector: `search_files`, `read_file` (a Doc as
  Markdown or text, a Sheet's first sheet as CSV, Slides as text, a text file
  as it is, a PDF as below), `list_permissions` (read); `create_document`, `edit_document`
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
- **Chat**, read only (`chat.spaces.readonly`, `chat.messages.readonly`):
  `list_spaces` (spaces, group chats and direct messages, with their last
  activity), `list_messages` (one space, newest first, between two times or
  in one thread), `get_message`. A sender shows by name where Google gives
  one to a person's sign-in (a member of the space, or someone they have
  talked with), otherwise by their `users/` id. Google offers a person no
  search of messages across spaces, so there is none. Chat needs a Google
  Workspace account, and reading needs only the API switched on and the
  client: no Chat app configured in the project.

The connector's token is renewed at Google's token endpoint with its client
when it is about to expire, and once more if Google turns it away; a sign-in
Google won't renew makes the connector need sign-in.


### Files and PDFs

`get_attachment` (an email's attachment, by the `attachment_id` that
`get_thread` and `get_message` list) and `read_file` on a PDF save the file on
the agent's computer, in `~/files/<folder>/<name>`, where its shell can open
it. The tool says where, with the file's name, type and size; Gmail's read
scope is enough, and nothing is asked for again.

- **How.** The tool's answer names the file; the sidecar then asks Rails for
  its bytes (`POST /agent/files`, inside the host only, within ten minutes of
  the call), and Rails fetches them from Google with the connector's own
  sign-in. The bytes are written to the computer and kept nowhere else: not
  in the ledger, the model's context, or Rails' storage.
- **A PDF's words** are read on the computer, by `agent/guest/pdf-text.mjs`
  with poppler's `pdftotext -layout`, each page under `--- page N ---`. A page
  with no text layer, a scan, is drawn at 200 dpi and read by tesseract
  (English). The first 30 pages, up to 60,000 characters, come back with the
  call, marked as information, not instructions; the whole text is saved
  beside the file as `<name>.txt`.
- **Limits.** 25 MB a file. A name keeps no folders, control characters or
  leading dots, and at most 120 characters. Nothing on the computer reaches
  the network for this; Rails reaches only Google.
- **Where.** Only on a Sprite: the computer image carries poppler and
  tesseract. On an SSH or local computer the tool says what the file is and
  saves nothing.
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
