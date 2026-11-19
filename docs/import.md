# Moving an install in as a workspace

Another install of this app can come into this one as a shared workspace:
its people, agents and threads, with everything they hold, moved over from a
copy of its storage. `bin/rails workspaces:import` does it
(`Workspace::Import`). It reads the copy and never writes to it. It writes
nothing here unless everything can come, and the same copy never comes twice.
It comes into a new shared workspace, or, with `WORKSPACE=<id>`, into a shared
one here that its owner owns (never a personal one).

It brings in, each with a new id here and every reference following:

- **People.** Both installs sign in through the same provider (the same
  `OIDC__ISSUER`), so a person is matched by their sign-in subject
  (`users.oidc_sub`), whatever their email is now: they keep their own
  settings and devices here. Anyone else comes as they were, without their
  SSH keyring name. Everyone becomes a member of the workspace. The person in
  the copy whose email is `OWNER` owns it (without `OWNER`, the copy's first
  person), and must already sign in here: the import is refused until they
  have signed in here once. Someone in the copy whose email belongs to a
  different person here is refused too, rather than made twice.
- **Agents.** Their settings, instructions and revisions, notes, prompts,
  skills and their files, documents and their versions, routines, permissions,
  computers' records, Concourse identities, Campfire and Telegram bots (with
  the posts a Telegram bot heard), mail accounts and their folders, and
  calendar servers. A release older than these
  tables (any before 16 November 2026) has none to bring: there, an agent's
  mail is its address on the install's domain and its CalDAV account, both
  columns of the agent, and they come with it.
- **Connectors.** Only the owner's own, switched on there, come, with their
  settings (address or command, scope, tools switched off, asks before every
  write) and which agents use them as core. Nothing they signed in with or were
  given comes: no OAuth sign-in or client, and no pasted key, header or
  command environment. A connector holds the credentials of whoever set it up,
  and in a shared workspace every member reaches it. Each that held a sign-in
  or a key is listed to reconnect, in the report (`Reconnect:`) and on the
  workspace's Connectors page: one that signed in shows **Sign in again**, one
  click; one that held a key says to remove it and add it again with its key.
  Switched-off connectors and other people's stay; others set theirs up again
  here. Every workspace names its connectors once, and the owner's from all
  the copy's workspaces come into one: two with the same name, or one whose
  name `WORKSPACE` already has, refuse the import, naming each and where it
  is. Rename or switch one off on the other install, make a fresh copy, and run
  it again.
- **Threads.** Conversations with their branches, messages, cards and their
  answers and approvals, payment requests, uploads, helpers, peer tasks,
  workflows, held emails, and the files attached to them (a message's
  pictures, a card's held files, an upload).
- **Secrets.** Every encrypted column but connectors' is read with the other
  install's keys and written again under this install's. If any value cannot
  be read, the import is refused, naming the column. Column by column:

  | Column | What happens |
  |---|---|
  | `agents.passbolt_private_key`, `passbolt_passphrase`, `caldav_password` | Re-encrypted: the vault and calendar accept them from anywhere. |
  | `concourse_agents.client_secret`, `push_token` | Re-encrypted: the identity's client works from any host. |
  | `campfire_bots.bot_key`, `telegram_bots.webhook_secret` | Re-encrypted; the webhooks are pointed here afterwards. |
  | `mcp_servers.token`, `headers`, `env` | Not carried. A key was given to the other install; the owner gives it again here (above). |
  | `mcp_servers.oauth_client`, `oauth_tokens`, `oauth_pending` (and `oauth_state`) | Not carried. A sign-in (Google's included) was made through the other install's OAuth client, and its tokens belong to that client. The connector comes marked for a fresh sign-in, which the owner makes here. |
  | `users.link_session` | Re-encrypted. |
  | `conversation_submissions.payload` | Stays with its table (below). |
- **Threads, in the sidecar.** A thread's history lives in the sidecar's store,
  not only in Rails' messages. Put the other install's store in the copy (a
  backup set's `agent-durable.sqlite`, or the volume's `agent/durable.sqlite`).
  Once the rows are committed, each thread is asked of this install's sidecar
  under its new ids, naming the copy of the store and the thread's id there.
  The sidecar starts it with what its model saw there, as one entry, so the
  next answer follows on rather than starting over (`agent/carry.mjs`).
  The messages on screen are the ones imported; pulling from the sidecar starts
  after the carried entry. Asked again, the sidecar finds the same thread, and
  a carried thread is never asked for again. If the sidecar is down, the
  import is kept and the summary says how many threads wait:
  `SOURCE=... bin/rails workspaces:carry` carries what is left and changes
  nothing else. A store that does not hold every thread the database names is
  from another moment, and the import is refused. Without a store in the copy,
  threads start afresh: the model sees only their new messages, and the
  summary says so.
- **Computers' files.** A local computer keeps each thread's files in
  `agent/computers/bot-<agent>/<thread>`. They come with the carried thread,
  into its new agent's and thread's folder. Each file's SHA-256 is recorded
  before the copy and checked after, and kept in the import's record
  (`computer_files`); `workspaces:carry` checks them all again and fails
  naming any that differ. Links are not followed. A Sprite's or an SSH host's
  files stay where they are: the summary lists them (`On its host:`, with the
  old Sprites' names), and copying them is a step on that host.
- **What the words name.** Every URL, email address and Campfire room number
  in agents' instructions, notes, prompts, skills and their files, routines,
  documents, and Campfire bots' rooms is listed in the summary
  (`Refers to:`), rehearsal included, and in the import's record
  (`references`), with where it is here. None is rewritten: another Campfire's
  room 12, or the other install's host, may mean something else from here.
- **Limits.** An agent's mail name (`email_name`) is unique across an
  install: one already here refuses the import rather than being renamed.

## What stays behind

The report lists, by name and number, every row and column it leaves.

| Stays in the copy | Why |
|---|---|
| The other sidecar's ids (`conversations.durable_id`, `last_entry_id`) | The thread is carried under an id of this sidecar's (above). Imported entries are renumbered below zero, in order, so new ones follow them and never share a key. You cannot branch from an imported message. `Conversation#resync!` on an imported thread pulls only what this sidecar holds: the carried context and what came after. |
| Another person's connectors, and connectors switched off there | The owner imports only their own; others set theirs up again here. |
| Connector sign-ins and keys (`mcp_servers.oauth_*`, `token`, `headers`, `env`) | A sign-in was made through the other install's OAuth client, and a key was given to that install. The owner reconnects each (`Reconnect:`). |
| The other install's own install connectors (`mcp_servers.install`) and core connector choices that name them | The imported workspace has none of this install's until its owner, or the install's owner, turns them on on its Connectors page (`docs/office.md`, Turning one on); the install's own key only where the install's owner owns it. Choose core connectors again if needed. |
| SSH keyrings (`users.ssh_keyring`, `computers.ssh_keyring`) | Keys held by the other sidecar. An imported SSH computer uses its agent's own key here (`agent-<id>`): add that key's public half on the machine. |
| `conversation_submissions` | The other sidecar's sending record. |
| Devices, watches, Share sheet drafts, Campfire room pauses, visits | Tied to the other install's address, or to a person's own browser. People turn notifications on again here. |
| Screen passes, sign-in links, inbound emails, image variants | Short-lived, or made again when needed. |
| A newer copy's own workspaces, memberships, invitations and imports | All its agents come into one workspace. |
| The cache, queue and cable databases | Each install builds these itself. Only `production.sqlite3` holds what people made. |

People already here keep their own name, notification choices and wallet. The
copy's values for them are not used.

## Before you start

- This install must be at a release with this task. It must be the same release
  as the other install, or newer: a copy from a newer release is refused.
  Upgrade first.
- Finish or answer what is waiting on the other install: running threads,
  waiting cards and held emails. A waiting card that comes over can't wake the
  old sidecar.
- Stop the other install (web, job and agent roles), then make the copy. Its
  routines, mailbox, Concourse identities and bots must not run in two places.
- The owner signs in to this install once, through the same provider.

## Make the copy

Use a checked backup set. On the other install's host:

    sudo systemctl start <service>-backup.service
    BACKUP_SERVICE=<service> ops/backup/durable_assistants-restore.sh "" /tmp/<service>-copy

The scratch folder now holds `production.sqlite3`, a `.backup` snapshot that
passed `integrity_check`, with the files under `storage/`, and the sidecar's
store as `agent-durable.sqlite`, checked against its manifest. A local
computer's files are in `storage/agent/computers/`. Or copy a stopped
install's volume yourself: run
`sqlite3 storage/production.sqlite3 ".backup /tmp/copy/production.sqlite3"`
and copy the two-character file folders beside it. A database with a non-empty
`-wal` file is refused: it can be missing recent writes.

The import opens the copy as immutable and read only. The copy's digest is the
same before and after, and it can be used for any number of rehearsals.

## The keys

The other install's encryption keys are input. Never put them in a command's
arguments. Put either of these in a file, readable only by you
(`chmod 600`), and pass its path as `SOURCE_KEYS`:

- what `bin/rails credentials:show` prints in the other install's folder, with
  its master key. Its own `active_record_encryption` keys are used if it has
  any; otherwise its `secret_key_base`, as its initializer derives them; or
- just `secret_key_base: ...`.

Keys derived from a `secret_key_base` are derived the same way in every
process (`DurableAssistants::EncryptionKeys`): as the web and job processes
always derived them, which the import task writes with, so the web reads what
it wrote. Before that, a task like this one derived other keys from the same
secret, and what it wrote the web could not read; those are still read, from
either install.

Alternatively, put `SOURCE_SECRET_KEY_BASE` in the environment, for example
with `read -rs SOURCE_SECRET_KEY_BASE; export SOURCE_SECRET_KEY_BASE`. Delete
the file when you are done.

## Rehearse

Rehearse on copies of both installs before running it for real. In a checkout
of this release, with a copy of this install's `production.sqlite3` as the
database (development uses `storage/development.sqlite3`), run:

    cp /tmp/this-install-copy/production.sqlite3 storage/development.sqlite3
    bin/rails db:migrate
    SOURCE=/tmp/<service>-copy SOURCE_KEYS=/tmp/keys.yml OWNER=owner@example.com NAME="Old office" \
      REHEARSE=1 bin/rails workspaces:import

`REHEARSE=1` does everything, prints the report, then undoes it, including the
files it stored. The report is the diff:

    agents                  2 in the copy        2 came        0 stayed  checksum ok 3f1c…
    mcp_servers             3 in the copy        2 came        1 stayed  checksum ok 9a0e…
    Stayed: 1 mcp_servers, the other install's own connector to its wiki or CRM: …
    Not carried: conversations.durable_id: the other sidecar's thread, …

Each line covers one table. For each table, every row is counted as either
imported or left behind, with the reason. Two checksums cover every column
written. One reads the copy with its keys and maps each reference to its new
id. The other reads this database back and decrypts with this install's keys.
If they differ, or a row is missing, the import is undone and the differing
tables are named.

Before anything is written, it refuses with every reason at once. Reasons
include: an agent address, phone number, Campfire bot, Concourse identity or
workflow step already here (an earlier import, or the same identity set up
twice); an owner who does not sign in here, or does not own `WORKSPACE`; a
person whose email is someone else's here; a connector name already in
`WORKSPACE`, or one the owner has in two of the copy's workspaces; a
`WORKSPACE` that already holds another import; keys that cannot read a column; missing attached files; a sidecar
store missing threads; an unknown table; or a newer release. An agent over the
tool limit is refused once its rows are written, and nothing is kept.

A rehearsal does not carry threads, since the sidecar would keep them; it says
how many would carry, or that they would start afresh.

## Run it

Run it without `REHEARSE` in the live install's web container, with this
install's sidecar running, and the copy and key file in its storage volume
(the sidecar reads the copy of the store only from there):

    SOURCE=/rails/storage/import SOURCE_KEYS=/rails/storage/import/keys.yml OWNER=owner@example.com NAME="Old office" \
      bin/rails workspaces:import

It ends with `Imported as workspace <id>`, after the threads are carried. The import is recorded
(`workspace_imports`: the copy's digest, its release and the report). The same
copy is refused afterwards. A later copy of the same install is refused by its
agents' addresses, which are already here.

## After it

What pointed at the other install now has to point here. The import contacts no
outside service.

- **Connectors.** Go through the `Reconnect:` lines, or the workspace's
  Connectors page: sign in again, or add each keyed connector again with its
  key.
- **Mail.** Agents keep their addresses. Point the other install's mail domain
  (`MAIL__DOMAIN` routing) at this install, or give the agents addresses here.
  Their own mail accounts sign in from here with their vault entries.
- **Phone.** Point each number's voip.ms SMS webhook at this install.
- **Campfire and Telegram.** Each bot keeps its webhook token. Change its
  webhook's host in Campfire, and register the Telegram bot's webhook again.
- **Concourse.** Identities come with their cursors. This install's sweep
  reads them from now on.
- **Computers.** A Sprite is named after its conversation's id, so each
  imported thread gets a new one. Copy anything needed from the old Sprites
  the summary names. A local computer's files came with their threads.
- **References.** Go through the `Refers to:` lines: a Campfire room, an
  address or an email that should now be another, change in the agent's
  settings.
- **Sign-in.** Imported people get in as members of a shared workspace
  (`Admission`). An install that serves one person (`ACCESS__OWNER_EMAIL`)
  admits nobody else.

## Retire the other install

When the people in the workspace have checked their agents and threads:

1. Keep the other install stopped. Keep its last backup set and the copy, by
   its backup retention, until you no longer need to roll back.
2. Move its mail domain, numbers, bot webhooks and DNS here, as above.
3. Revoke its OIDC client at the sign-in provider, and remove its Kamal
   destination, secrets and backup units from its folder.
4. Delete its Sprites once nothing more needs to be copied from them.

To undo an import before retiring: stop the agents in the workspace, delete
its agents (which takes their threads and connectors), then delete the
workspace. Its `workspace_imports` row goes with it. The other install, still
stopped, is unchanged.
