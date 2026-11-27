# The office

Every install runs an office beside the app: the services where its people and
agents work together. The template owns it. An install brings its hosts,
addresses and secrets; the person's own tools (their employer's systems, their
own mail) are theirs, reached as connectors or through an agent's computer.

| Service | What | Accessory | How agents use it |
|---|---|---|---|
| Chat | Basecamp's Campfire | `campfire` | Each agent is a bot (`docs/campfire.md`). |
| Wiki | Outline | `wiki`, `wiki-db`, `wiki-redis` | A connector every agent has, once `WIKI__API_KEY` is set. |
| Code | Forgejo | `code` | From an agent's computer, like a person. |
| CRM | Twenty | `crm`, `crm-worker`, `crm-db`, `crm-redis` | A connector every agent has, found when needed, once `CRM__API_KEY` is set. |
| Vault | Passbolt | `passbolt`, `passbolt-db` | Saved sign-ins (`docs/passwords.md`), once the agents' user's key is set. |

All of it is in `config/deploy.example.yml`, each image pinned by version and
digest. An install copies that file once as its destination file
(`docs/deployments.md`) and fills in its own hosts, addresses and names.

## One address rule

The app reaches each service inside the host, at
`http://<service>-<accessory>`, the name Kamal gives the accessory's container
on the host's Docker network: `http://acme-campfire`,
`http://acme-wiki:3000/mcp`. Campfire reaches the app the same way, at
`http://<service>-web`, the web role's network alias. The service comes from
the app container's own name (`DurableAssistants.kamal_url`), so an install
sets none of these. People's addresses (chat.example.com and the rest) are for
browsers only, and may sit behind the install's sign-in page; the app never
uses them.

A service somewhere else is named by its setting: `CAMPFIRE__URL`,
`WIKI__URL`, `CRM__URL`, `PASSBOLT__URL` (`.env.example`).

## What agents may do

The rule for each connector is in `config/install_connectors.yml`, as shell
patterns over the server's tool names, with the policy above each:

- **Wiki.** Read everything; write documents, comments and attachments.
  People arrange collections. Attachments go through the wiki's connector
  address, not its public address, which may sit behind a sign-in gate the
  agent can't pass.
- **CRM.** Read every record; write people, companies, opportunities, notes,
  tasks, attachments and the links between them. The CRM itself (fields,
  views, roles, webhooks, workflows, dashboards), its connected mail accounts
  and sending email stay with people.
- **Everywhere.** Deleting, merging and restoring are people's. No pattern
  matches those verbs.

### Wiki attachments

**Upload.** `mcp__wiki__upload_attachment(attachments, name?, content_type?)`
takes one path in `attachments`, a one-item list, from the agent's computer.
It uses the same file handoff and limits as `send_email` ([email](email.md)).
The filename and its type default from the file's name. The wiki's write
policy applies; where approval is needed, the card names the file and its
size and the approval holds to those bytes. The result gives the
attachment's URL, ID, name and size. The file starts unattached: use its
returned URL to add it to a wiki document.

The install's Outline entry opts in with `uploads_attachments: true`,
separate from the download flag. Existing connectors need a tool refresh.
Rails alone calls `create_attachment`. It accepts only a signed POST form
for `/api/files.create`, not a PUT upload, and refuses a file over Outline's
advertised limit. It streams the file from disk to the connector's address,
with the public Host and scheme for routing. It sends the form's signature,
not the connector key. Only HTTP 200 with JSON `{"success":true}` confirms
storage; redirects are never followed. Connects, reads and writes each have
the same 30-second wait limit as downloads.

**Download.** `fetch` of an attachment lands in the agent's `~/files`, as
a Gmail attachment does (`McpServer::WikiAttachment`). The install entry
opts in with `fetches_attachments: true`, not by its name. Only
`/api/files.get` and `/api/attachments.redirect` are allowed, with at most
one redirect on the link's own host; the request and key always go to the
connector's address. A download has no size limit: it is written to a
temporary file as it arrives, never held whole, and streamed on to the
sidecar. Each wait for bytes (connecting, the headers, each read, on the
redirect too) gets 30 seconds; there is no total deadline, so only a wiki
silent for 30 seconds is given up on. Redirect and error bodies are not read.

### An install's own connector

An install that needs one more, such as a service of its own inside its
network, adds it in `config/install_connectors.local.yml` rather than
replacing core's file. It is read the same way (a `shared:` key, ERB,
settings through `Rails.app.creds`) and merged after core's, and its entries
are held to every rule above: plain http only to its own address's host,
`tools` patterns, `loaded`, and nobody has it until its `api_key` is set. A
name core already uses fails the boot rather than replacing core's entry.
A setting it reads goes in the install's `.env.example` beside core's.

`test/models/office_tools_test.rb` holds each rule against the full tool list
of the pinned version (`test/lib/office/`). When a version bump changes a
server's tools, record the new list there and the test says what the rule
admits.

## Setting it up

Once per install, after the first `bin/kamal accessory boot all -d <name>`:

1. **Chat.** Open Campfire and make its first account, the administrator. Put
   that sign-in in the vault as `CAMPFIRE__ADMIN_EMAIL` and
   `CAMPFIRE__ADMIN_PASSWORD`; the app then makes each agent's bot.
2. **Wiki.** Register a sign-in client for the wiki's callback
   (`https://<wiki address>/auth/oidc.callback`) with the install's OpenID
   Connect provider, as `WIKI_OIDC_CLIENT_ID` and `_SECRET`. Sign in, add a
   member for the agents, and make it an API key: `WIKI__API_KEY`.
3. **Code.** Add the provider as Forgejo's authentication source, once:
   `bin/kamal accessory exec code -d <name> --reuse "forgejo admin auth add-oauth --name <provider> --provider openidConnect --key <id> --secret <secret> --auto-discover-url <issuer>/.well-known/openid-configuration"`.
4. **CRM.** The first person signs up and makes the workspace. Make an API key
   for the agents in its settings: `CRM__API_KEY`.
5. **Vault.** `docs/passwords.md`, Adding it to an install, from step 2.

Each key goes into the vault, `.kamal/secrets.<name>` and the web and job
roles' secrets, then deploy the app. Until a key exists, leave its lines out:
that part of the office stays off for agents, and people can use it already.

## Turning one on

No workspace has the wiki or CRM until it is turned on there, under Office
connectors on its Connectors page, by the workspace's owner, or by the
install's owner if they belong to it. The install's owner, here, is
`OFFICE__OWNER_EMAIL`, matched whatever its case and surrounding spaces, and
nobody else. Never its admins (`ACCESS__ADMINS`), who manage the model
accounts and invitations but not what the office's keys reach. Unset, there is
no such owner, so no workspace uses the shared keys and each turns one on only
with a key of its own. Setting it changes nobody's sign-in, admission or
invitations; `ACCESS__OWNER_EMAIL`, which signs everyone in as one person, is
a different setting and says nothing about the office's keys. The shared keys
above are the owner's: only a workspace the install's owner owns uses them. Any other
workspace turns one on only with a key of its own (below), so a person who is
not the install's owner never reaches, through their own workspace, what the
install's key reaches.

Any member switches one off on its page; only the workspace's owner or the
install's switches it back on. The install never switches one back on by
itself. One in a workspace that may not use the shared key and has none of
its own is switched off, never deleted, on the next run of
`InstallConnectorsJob`, and the log says so once.

## A workspace's own key

A workspace the install's owner does not own needs its own key to have the
wiki or CRM. A shared workspace whose people should see only their own
collections (a client, an outside pilot) gets its own too: make a wiki member for
it, put it in an Outline group that holds only the workspace's collections,
and make that member an API key (as "An agent acting as itself" below). The
workspace's owner pastes the key on the workspace's page, under Office
connectors (`Workspaces::InstallConnectorsController`), with an address if the
workspace's wiki or CRM is elsewhere, then turns the connector on. The key is
encrypted and never shown again; members see only that the workspace has its own.

The workspace's connector uses that key and address for MCP calls. The
wiki attachment download also uses that key; for uploads, only the MCP
call to prepare the form needs it. No other workspace's agents ever send
it. The office's tool limits and `loaded` still hold. An address other
than the install's own must be public https: it is
reached as a person's connector is, never this server or its private network.
The one exception is a host the operator lists in `CONNECTORS__INTERNAL_HOSTS`
(comma-separated, each an exact name such as `example-wiki-2`, or
`example-wiki-2:3000` for that port alone): a workspace's address may name it
over plain http, as `http://example-wiki-2:3000/mcp`, and it is reached inside
the host as the install's own is. Only the operator sets the list; a
workspace's owner chooses among listed hosts but cannot add one, and the list
opens nothing for a person's own connector or any other name or address.
The workspace may have the connector even when the install's own key is not set.
Remove it on the same page and the connector goes back to the install's key in
a workspace the install's owner owns; anywhere else it is switched off (or,
with no install key either, removed). A personal workspace's person does the
same on their own workspace's page, or from Set its own key on the Connectors
page; nobody else, even someone added to it, reaches that page.

An install's connector with no install key at all (one whose agents each act
as themselves, below) is still listed in a workspace the install's owner
doesn't own: off, and working there once that workspace has its own key. Its
row says so rather than that the install's key is kept from it, since there is
none (#241).

## An agent acting as itself

With the shared keys above, every agent works in the wiki and CRM as one
member, so the office shows one name for all of them. To have the wiki show
"Jordan edited this", the agent needs a wiki member and a key of its own.
Outline lets only a member make its own key, and agents have no account at
the install's identity provider, so the agent's member signs in by email
instead (Outline 1.12, from its source):

1. **The wiki sends mail.** Its accessory has the `SMTP_*` settings and the
   two `WIKI_SMTP_*` secrets (`config/deploy.example.yml`); Outline offers
   email sign-in only with them. Then, signed in as a wiki admin, turn on
   email sign-in in the workspace's security settings. People keep signing
   in through the identity provider as before.
2. **Invite the agent.** In Members, invite the agent's own address
   (`docs/email.md`) as a member, with its name. The invitation lands in
   the agent's thread.
3. **Sign in as the agent.** In a private window, choose to continue with
   email and give the agent's address. Outline sends a link and a six-digit
   code to it, so they arrive in the agent's thread too, as untrusted mail.
   Take them from there and sign in. (Outline sends a member who signed in
   through the identity provider back there instead, so this works only for
   an address no one has used that way.)
4. **Make its key.** Still signed in as the agent, make an API key in its
   settings, then sign out. Give it to the agent with the console line
   below.

The CRM can't do this with keys: a Twenty key belongs to the whole workspace,
and its edits show as the key, never a member, whichever agent holds it. Only
signing in as a member, through Twenty's OAuth, would; that is not built.

With a wiki key of its own, in a console on the web role:

```ruby
agent.conversation.mcp_servers.create!(user: agent.user, name: "wiki", install: "wiki",
  url: McpServer.install_entries["wiki"][:url], token: "<Jordan's wiki key>")
  .then { McpServerRefreshJob.perform_now(it) }
```

That connector replaces the shared one for this agent alone, and the office's
address rule and tool patterns still hold. They hold without the shared key
too, so an install whose agents all act as themselves can leave
`WIKI__API_KEY` unset. Destroy the row to put the agent back on the shared
member. In the vault, an agent's own Passbolt user does the same
(`docs/passwords.md`). Code has no connector: an agent's own Forgejo token
belongs on its computer, with git.

## Backups

`ops/backup/durable_assistants-office-backup.sh` backs up the office nightly,
beside the app's own backup (`ops/backup/README.md` installs both). It reads
each accessory through `docker exec`, checks every file, and publishes one
generation directory under its `BACKUP_STAGE_DIR` (`/var/backups/<service>-office-backup`, say), keeping
the newest two; the host's own backup (borgmatic, say) keeps the history. The
two Redis accessories hold only queues and caches, and are not kept.

Restoring is by hand, one accessory at a time, from a generation:

| File | Restore to live |
| --- | --- |
| `passbolt.sql` | stop `<service>-passbolt`; `docker exec -i <service>-passbolt-db sh -c 'MYSQL_PWD="$MARIADB_PASSWORD" mariadb -u"$MARIADB_USER"' < passbolt.sql` (the dump drops and recreates each table) |
| `passbolt-keys.tar` | untar into the folder its `directories:` mount, keeping owners `www-data` (gpg) and `root:www-data` (jwt) |
| `wiki.dump`, `wiki-data.tar` | stop `<service>-wiki`; `pg_restore -U outline -d outline --clean --if-exists` in `<service>-wiki-db`; untar into the wiki's data volume |
| `crm.dump`, `crm-files.tar` | stop `<service>-crm` and `<service>-crm-worker`; `pg_restore -U twenty -d twenty --clean --if-exists` in `<service>-crm-db`; untar into the CRM's files volume |
| `campfire.sqlite3`, `campfire-storage.tar` | stop `<service>-campfire`; copy to `db/production.sqlite3` in its volume (remove `-wal` and `-shm`); untar the rest |
| `forgejo.tar` | stop `<service>-code`; Forgejo's "restore from dump": `sqlite3 data/gitea.db < forgejo-db.sql`, `data/` and `repos/` back into its volume, `app.ini` into its config |

Drill a restore into throwaway containers before trusting a new install's
backup. Until a repository is pushed, Forgejo has no repository root and the
dump skips repositories (noted in `backup.log`).

## Updating

At every update of the pinned commit, read what changed in the office:

```shell
git diff <old commit> <new commit> -- config/deploy.example.yml
```

and make the same change in the destination file, usually a new image pin.
Then `bin/kamal accessory reboot <accessory> -d <name>` for each one bumped,
after a backup. Never `kamal accessory remove passbolt`: an install that keeps
the vault's keys in Kamal `directories:` would lose them.
