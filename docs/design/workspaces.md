# Workspaces

Status: decided by the owner on 15 November 2026 (section 5). The first
slice of G is built: `Workspace` and `Workspace::Membership`, each person in
a personal workspace of their own. A workspace may now be shared: many
members, exactly one owner (roles `owner` and `member`, alike except that
only the owner will invite and remove), and a request works in one,
`Current.workspace`: the one its record or its address names, otherwise the
one the person used last, which the session names while they belong to it.
Settings lists the person's workspaces, their own first (Workspaces,
`/workspaces`), with New workspace. A person makes a shared workspace, named,
and owns it (`/workspaces/new`); a member renames it, and a person renames
their personal one, which until then goes by their name. Either name is at
most 100 characters; a refused rename leaves the page naming the workspace as
saved. Each workspace's page
(`/workspaces/:id`), reached from Settings and from its name heading its group of agents,
lists a shared one's members and, for the owner, its pending invitations,
with the invite form; a member leaves it there. A personal
one's page has its name and its billing. The owner
invites an email (`Workspace::Invitation`: workspace, email, inviter). Once
approved, it admits the email to the install (`Admission`) and, where the
install sends mail (`MAIL__SMTP_ADDRESS`), is told by `WorkspaceMailer`:
from the workspace's own mail domain, through its server, where it has one
(`docs/email.md`). An
invitation by one of the install's admins (`ACCESS__ADMINS`) is approved as
it is made; anyone else's waits in Settings, Invitations, until an admin
approves it or declines it, cancelling it. Who comes in, and what the
install mails to someone outside it, are the install's to decide, not a
workspace owner's. Without mail, the page shows the link to share. Signing in through the usual door with that email,
verified, turns the invitation into a `member` membership and starts the
person in the workspace. Someone who has already signed in with that email,
and is still let in, is made a member at once, with no email, and finds the workspace in their
agents list. The owner removes a member or
cancels an invitation, and a member leaves; nobody removes the owner. The
owner hands the workspace to a member ("Make owner"), staying as a member,
who may then leave too. Someone
admitted only through workspaces is out of the install, at their next
request, once they are in no shared workspace and invited to none; leaving
the last one, they are warned first, then signed out and told why. In an
install that serves one person (`ACCESS__OWNER_EMAIL`) a workspace admits
nobody: its workspace pages say inviting needs single-owner mode off, no
invitation is made, and none is accepted at sign-in. Each sign-in there by an
email other than the owner's is logged, naming nobody, and listed with its
email on the owner's Settings, You. What asks a person first (`send_email`, `calendar_save_event`) still
trusts only `ACCESS__EMAILS`, never an invitation.
The agents list, and a thread's sidebar, is one list of every workspace the
person is in, their own first, each a group (`Workspace::Group`,
`conversations/_group`, #174): the workspace's name, a link to its page, whose
it is (Yours, or how many people), how many cards wait on the person there,
counted as the badge counts them (`User#needs_you_by_workspace`), then its
agents' rows, thirty at a time, each group loading its next thirty as it
scrolls to its end. Nobody chooses a workspace to see its agents: the switcher
that did is gone. Search and filter run across every group and show only the
groups with something to show; the list as it stands shows every one, an empty
workspace saying so with a link to make its first agent there. Each group is
live on its own workspace's stream. Under the groups are Overview and New
workspace. Each group has a menu (a popover; on a phone an action sheet, the
thread's menu's look; not the phone app's bar menu, which holds one per screen):
New agent here, Connectors (`/workspaces/:id/connectors`), Helpers
(`/workspaces/:id/helpers`), Invite people… (its invite form, for whoever may
invite, `Workspace#invites_from?`: today the owner of a shared one) and
Workspace settings, its page. Each names its workspace in the address, so
where it leads is where the person came from, never a workspace
chosen once and kept: Work in it is gone (#174). New agent asks which
workspace, for someone in more than one: from a group's menu that group's,
inside a thread the thread's, and from the list's own button the one they used
last, shown on the form to change. A link to an agent, its settings,
its thread, a connector or a waiting card in another of their workspaces (a
notification, a shared link) opens it there, and that, or a workspace's page,
connectors or helpers opened, becomes the one they used last; a change, or
Turbo fetching ahead, never does. Whichever workspace the
session names, a request about one agent, thread or card (Allow, Decline or
Reply on a notice, a message sent from a phone tab still showing another
workspace) is allowed by the person's being in that record's workspace, and
works there without switching; one they are not in stays not found
(`Authentication#find_in_workspace`). The workspace used last chooses
only where the list's New agent starts, and which workspace Settings'
Connectors and Helpers rows open; each page names it. Share with…, for what
the phone's Share sheet hands over, offers the agents of every workspace the
person is in, each named for someone in several, and opens the one chosen in
its own. What an agent asks or
says reaches every member of its workspace, each on their own devices with
their own badge, once each, and nobody outside it (`Conversation::Notifiable`):
a card waiting (by email to a member with no device), a finished reply, an
error, and its texts paused for the day. A member's Watch lists the threads
and cards of all their workspaces and answers them there, as their phone's
notices come from all of them. Needs you lists the same cards, every one
waiting on them in all their workspaces, each naming its workspace when they
are in several, and the badge counts exactly those (`User#needs_you`).
Workspaces, Overview (`/workspaces/overview`), linked from Settings'
Workspaces and from under the agents list, shows each of
their workspaces, their own first, each block the same four sections, empty or
not: its agents, each working, idle, paused or in error as its stored run says, the cards
waiting (stuck after an hour, or sooner when one expires within the hour), the
calls that failed in the last day and the Campfire rooms held for spinning
(each with its name, why and since when, linked to the workspace's Campfire
section; a person's next word to any of its agents starts it again), each
a link to the page that deals with it, with no action of its own
(`Workspace::Health`). It reads only what is stored, never the sidecar or a
Campfire, and an admin sees only the workspaces they are in. Removed, a member hears nothing more, and
every "Always" they gave the workspace's agents goes with them (#40,
decision 2): the agents ask again. Kept personal: a device's test notice.
Step 2b scopes Concourse and Campfire by
workspace: its owner names a Concourse home network, and an identity
anywhere else is a bridge the owner approves (section 2.3); its agents' bots
relay, make rooms and pause loops among its agents and people only, on its
own Campfire if it names one (section 2.1). Connectors belong to the workspace
(`mcp_servers.workspace_id`, required): its agents use its connectors and its
own conversations', its members manage them on its connector pages, and a
person's personal connectors are never reached from a shared workspace, nor
its from their personal one. The install's connectors are in a workspace once its owner, or
the install's, turns them on, in its owner's name (`McpServer.turn_on`, #168). The second slice keeps who said each message: its
request id and author, a person or a channel's sender, ride on the sidecar's
entry for it, so two people's identical words stay apart after a restart or
a rebuild (`docs/agent.md`, "Who said it"). The workspace owns its agents:
every agent has one (`agents.workspace_id` is required), and a person reaches
an agent, its thread and everything of it only through the workspaces they
belong to, never as its maker. `agents.user_id` stays as who made it, and
`conversations.user_id` is written but no longer read; both are dropped
later. An agent's settings name its workspace, for someone in more than one,
and New agent makes it in the one it shows, which the person may change; an agent's
`make_agent` makes one in its own. The workspace's owner moves an agent to
another workspace she is in, from its settings (`/agents/:id/move`) or
through `move_agent` (`Agent::Movable`), logged. Its own things go with it:
its thread and history, notes, documents, skills, routines, computer,
address, number, mail accounts, calendars and bots, and its thread's own
connectors. What was the old workspace's stays there: its connectors, the
outside contacts routed to the agent and a member's choice of it as their
only contact. Anyone not in the new workspace takes back their "Always". A
Concourse identity is judged against the new home network, a bridge
waiting for the new owner; a Campfire bot stays on a Campfire both share,
forgetting the old rooms, and is otherwise made anew on the new one's. Its
usage so far stays billed where it was. A card still waiting is answered by
the new workspace's people. Mail goes on (`mail_to_agent`) only within one
workspace, so an agent in such a pair moves once that ends. The sidecar
reaches an agent through its maker, whether or not they are still in its
workspace. Agents do the rest of what the workspace pages do through six
tools picked one by one (`docs/permissions.md`, "A workspace's tools"). Whether a member of one workspace reaches anything of another is
asked by `test/integration/cross_workspace_leak_test.rb`, of every route,
page, stream, picture link and tool; a stream is heard only by its
workspace's members, or its person, whatever channel asks for it
(`StreamAudience`), and a picture only by someone who reaches what it is
attached to (`ReachableBlobs`). What every workspace still shares (the model
subscriptions, one Concourse server, and the install's Campfire for a
workspace without its own) is its
`SHARED_ACROSS_WORKSPACES`, until step 2 gives each workspace its own secrets
and identities. Step 2a is built: a shared workspace's owner may give it its
own Passbolt user and its own address and key for each install connector, on
its page (sections 2.2, 2.4 and 2.6); the install's Passbolt user and
connectors are shared only where a workspace sets none of its own. Its owner
may name, the same way, its own voip.ms account by vault entry, which its
agents' texts then go through (`docs/phone.md`, "A workspace's own voip.ms
account"); a number is still one agent's across the install. A workspace
sets the size of its agents' Sprites, and an agent its own, within the
install's maximum: its owner sets both, and a size reaches computers made after
it (`docs/computers.md`, "A Sprite's size"). Who pays is built as far
as the workspace (`docs/billing.md`): a workspace is billed to the install,
as before, until its owner chooses itself or another workspace they own
(`workspaces.payer_id`), and every model call's usage is recorded against the
workspace and agent that made it and the payer then (`ModelUsage`), shown to
its members on its Usage page by agent, model and payer. The calls still run
on the install's shared model accounts; a workspace's own accounts and #41's
agent and per-model levels are still to come. Another install
moves in as a shared workspace (section 4), a new one or one its owner owns
here, with `bin/rails workspaces:import` (`Workspace::Import`,
`docs/import.md`). It reads a copy of that install's storage and brings its
people (matched by sign-in subject), agents, threads and files, with new ids.
Its secrets are encrypted again under this install's keys, except
connectors': only the owner's switched-on connectors come, with no sign-in or
key, each listed for the owner to reconnect. A connector name that would come
twice into one workspace is refused. Its threads are carried into this
install's sidecar with what their model saw, and local computers' files with
them, each file's hash checked. What the agents' words name outside (Campfire
rooms, addresses, emails) is reported, never rewritten. Roles and every scoping in
section 2 are still to come. Team rules, step 4b (`docs/contacts.md`): a member may name
one of the workspace's agents as their only outbound contact, and every other
agent of it is refused mail, texts and card notices to their address or
number, naming that agent; the owner routes outside contacts to agents, whose
mail and texts to any agent of the workspace then reach the routed one alone.
Concourse mail is not rerouted: a task names an agent, never the person it is
for. A workspace has shared instructions
(`workspaces.instructions`, `Workspace::SharedInstructions`), which every
agent of it follows beside its own: a labelled section after the agent's own
instructions in its definition, so a change reaches each of its agents, and
no other workspace's, on its next message. Only the owner changes them, on
the workspace page; a member proposes a change there (`Workspace::Proposal`),
which the owner accepts or declines, and an agent proposes one through
`change_yourself` with `scope: "workspace"`, a card only the owner can allow,
even where the install approves everything (`docs/permissions.md`). Each
change is kept (`Workspace::Revision`): the text, who made it and who
proposed it, a member or an agent. A workspace may have its own mail domain,
server and catch-all box, which the install's operator sets: its agents'
addresses are at it and what they send goes from it, while an address's name
stays unique across the install (`Workspace::MailDomain`, `docs/email.md`,
#229). A workspace has its own approval policy
(`workspaces.approval_policy`, #226), chosen by its owner on its page; none
means the install's (`APP__APPROVE_EVERYTHING`, `APP__APPROVALS`), and what
asks even where everything is approved asks in every workspace
(`docs/permissions.md`). A workspace may go by its own name and
colour on its people's pages, which its owner sets on its page, and send the
links in its mail to a host of its own, which only the install's operator
sets and the install already answers on (`Brand`, `docs/deployments.md`,
#229). It replaces Group G's "one shared
agent with members and roles" (#40, decision 2) with a boundary that matches
how installs are really used: one install hosts several separate worlds (a
team, a client company, an outside pilot, a household, a family), each with
its own people, payer, network, rooms, wiki, computers and saved sign-ins.

## 1. What a workspace is

A **Workspace** is the boundary for everything an agent can reach. An agent
belongs to exactly one workspace, for life; moving one is an explicit,
logged act by a manager of both, never a side effect.

| Piece | Belongs to the workspace as |
|---|---|
| People and roles | `Workspace::Membership` (person, role): **manager** configures agents, accounts and grants; **member** talks to the agents and approves their calls; **viewer** reads threads. Roles come from #40 decision 2, now per workspace rather than per agent. |
| Who pays | `workspace.model_account`, the default in #41's resolver: install default, then workspace, then agent, then per-model override. A workspace may point at another workspace's account, chosen explicitly in its settings, never as a silent fallback. Every call still records the workspace and agent that made it, so usage splits out later; moving to its own account is a settings change, with no data migration. Test: an agent in one workspace bills to another's account, and its usage is attributed to its own workspace. Built: the install and workspace levels (`Workspace#payer`) and the record of every call (`ModelUsage`, `docs/billing.md`). |
| Concourse | One **home network** (organization). Its agents join that one. Other networks are *outside*: reached only by a bridge (section 3). |
| Chat | The workspace's Campfire rooms. Its agents' bots join only those. |
| Wiki | The workspace's wiki collections, reached with the workspace's own wiki key. |
| Connectors | Workspace-wide connectors (today's "all of a person's agents" level becomes "all of the workspace's agents") plus per-agent ones. |
| Computers | Each agent's computers (several, named, one default by tool kind; section 2.5). SSH targets a manager has allowed for the workspace. |
| Saved sign-ins | Owned by a person, held in the workspace, granted use-only to its agents (section 2.6). |

Small objects, no framework: `Workspace`, `Workspace::Membership`,
`Workspace::Bridge`, `SignIn::Grant`, `SignIn::Use`, `Computer` (now many
per agent). Every owned query goes through `workspace` the way it goes
through `user` today (`test/tenancy_scoping_test.rb` gains the owner).

**Single-person installs do not change.** Each person gets a personal
workspace, holding all their agents; nothing else moves. A workspace with one
manager behaves exactly as owner mode does today.

## 2. Today, and what changes

### 2.1 Chat (Campfire)

Today (`docs/campfire.md`): one Campfire per install. Every agent's bot joins
every open room. Agents pass messages only to "another of the person's
agents". Loop pausing is per room and tells "its person". Every person in
Campfire sees every open room and every user.

Change:
- A bot joins only its workspace's rooms; `campfire_make_room` adds the
  workspace's agents and **members**, not "every person in Campfire".
- The agent-to-agent relay matches by workspace, not by
  owner. An agent in another workspace hears nothing, even with the same name.
- The loop pause notifies the workspace's managers.
- Campfire ONCE has no spaces: open rooms and the user list are visible to
  everyone signed in. A workspace whose people must not see each other's
  rooms (an outside pilot, a client) needs **its own Campfire**
  (`Workspace#campfire_url`, an accessory per workspace). Households and
  teams of trusting people can share one, with closed rooms.

Built (step 2b): `Workspace::CampfireRoom` keeps a room's loop hold for the
workspace, and the pause tells each of its members once. The relay looks among the workspace's agents only, so an agent in another
workspace hears nothing, even with the same name. `campfire_make_room` names
the workspace's agents and lets in its members, matched by the name Campfire
shows. A workspace's owner may name its own Campfire (`campfire_url`, and
`campfire_vault_entry`, the saved sign-in of its administrator), on the
workspace's page; without one, the install's (`Workspace#campfire`,
`docs/campfire.md`). A bot still joins every open room of its Campfire:
Campfire gives a bot no choice.

### 2.2 The wiki (Outline)

Today (`docs/office.md`, `docs/connectors.md`): one Outline per install,
reached with one install key, so every agent reads every collection.
`McpServer::WikiAttachment` fetches attachments server-side with the same
key. An agent can have its own key only through a console.

Change:
- Each workspace has an Outline group and its collections, and **its own wiki
  member and key** (`Workspace#wiki_api_key`, encrypted). The wiki connector
  and the attachment fetch use the agent's workspace key, so Outline's own
  collection permissions bound what is read and written.
- The install-wide key remains only for an install with one workspace.
- Per-agent wiki members stay possible (attribution), but their key belongs
  to a member of the workspace's group only.
- A test: an agent cannot list, fetch or attach from another workspace's
  collection, through the tools or the server-side fetch.

Built: a workspace's own wiki key, and address if it has its own wiki
(section 2.4), on its page. The wiki connector and the attachment fetch use
it (`test/integration/wiki_files_test.rb`), and another workspace's agent
never sends it (`CrossWorkspaceSecretsTest`). Making the Outline group and
member for a workspace is the install's, in Outline (`docs/office.md`).

### 2.3 Concourse

Today (PLAN.md decision 6): one Concourse server per install. An agent may
hold one identity in *each* organization it joins (`ConcourseAgent`, many per
agent). Concourse mail is always untrusted. A task stays on the network it
came on.

Change:
- An agent joins only its workspace's home network. A second identity is no
  longer an ordinary join.
- An agent that must speak on another network is a **bridge** (section 3),
  made by a manager of both sides, not by joining twice.
- Each network is labelled for the workspace as **home** or **outside**
  (pilots, partners). Mail from both stays untrusted to the model. Outside
  traffic additionally needs a person's approval to send.

Built (step 2b), as the smallest sound model: no `Workspace::Bridge` table.
A workspace's owner names its home organization (`workspaces.concourse_home`,
on the workspace's page). An identity anywhere else is a bridge, its approval
two columns on the identity (`concourse_agents.bridge_approved_by_id`,
`bridge_approved_at`, `ConcourseAgent::Bridge`). A member's join there waits:
the identity reads and sends nothing, and the agent has no `concourse_` tools
through it, until the owner approves it on the agent's Channels page, which is
logged. The owner's own join is approved as it is made. Naming a home approves
every identity already speaking outside it, in the owner's name, and the
migration does the same for every identity there was. With no home named,
every join is as before. Each send onto a bridge asks a person, with no
"Always", even where the install approves everything.

### 2.4 Connectors

Today: `McpServer` belongs to a user (all their agents) or a conversation
(one agent). Install connectors (wiki, CRM) reach every person.

Change: the "all agents" level belongs to the workspace. Install connectors
are configured per workspace (address and key). #42's lookup-first defaults
and per-agent moves apply unchanged within the workspace.

Built: every connector has a workspace (`mcp_servers.workspace_id`, NOT NULL
since migration 20261115190000, which filled any left empty), and is reached
through it: the connector pages, sign-ins and refreshes through
`Current.workspace`, a run through its agent's workspace. A name is unique
within a workspace. Whoever added one (`mcp_servers.user_id`) need not be who
manages it: every member does. An install connector is in a workspace only
once the workspace's owner, or the install's owner
(`OFFICE__OWNER_EMAIL` alone, never its admins; unset, nobody; not
`ACCESS__OWNER_EMAIL`) who belongs to it, turns it on on its
Connectors page (`McpServer.turn_on`, #168), made in the workspace owner's
name. The install's own key is used only in a workspace the install's owner
owns; any other needs
its own address and key for it (`Workspace::InstallConnector`, migration
20261117010100, encrypted): its connector then uses those for every call, and
no other workspace's does. Its owner sets them on the workspace's page, under
Office connectors; its members see only whether each is set. An address other
than the install's own is public https and pinned, as a person's connector is.
`McpServer.install_for` keeps the ones turned on in line and never makes one or
switches one back on; one an earlier release made in a workspace that may not
use the install's key, and that has none of its own, is switched off, never
deleted, with one log line (no migration: the first run after the deploy does
it). A personal workspace's owner sets its own key on the same page, found
only among the workspaces they own.

### 2.5 Computers

Today: `has_one :computer` with a unique index (`computers.agent_id`), and the
definition carries one `computer&.descriptor`.

Change (high priority, before G, from the multi-computer item):
- `has_many :computers`; each has a name and a kind. An agent has one primary
  per role: **files** (file, shell, code tools) and **screen** (browser,
  screen, desktop, saved sign-ins). An agent with one computer uses it for
  both, as today.
- The definition carries the list. The computer tools take an optional
  `computer` argument; no new tool per computer, so the tool count does not
  rise.
- Filesystem first is an **install setting, off by default**. Off, nothing
  changes: a new agent gets exactly one desktop computer, with no SSH
  primary, as today; the template and other installs stay desktop-only. On,
  a new agent gets an SSH computer as the files primary with a desktop
  optional, and an existing agent can attach an SSH computer and make it
  primary. The ability (named computers, routing by tool kind, a name in the
  call overriding it) exists either way.
- Tests: with the setting off, a new agent and a fresh install are exactly
  as today, one desktop computer per agent; on, a new agent gets an SSH
  primary; routing; attach and switch.
- Moving files between computers is an explicit, hash-checked step, never
  automatic.
- The migration drops the unique index and marks each existing computer as
  both primaries.
- SSH keys and host trust are each agent's own (`computers.ssh_keyring`,
  issue #59, built); computers made before keep their person's. One Unix
  account per agent: two agents on one account share its files.

### 2.6 Saved sign-ins (password manager)

Today (`docs/passwords.md`): one Passbolt per install. A folder is shared
with a single agents' user, or an agent has its own Passbolt user, set in a
console. Every use is approved. The secret goes only into the agent's
browser. Grants are managed in Passbolt, out of the app's sight.

Change:
- **Ownership.** Each saved sign-in has an owning person and lives in one
  workspace (the workspace's Passbolt folder or group).
- **Grants.** `SignIn::Grant` (agent, entry or folder, optional site) is
  use-only: the agent can fill, never read. Rails checks the grant at each
  password request (`POST /agent/sign_ins`), so revoking applies on the next
  use. A grant naming another workspace's entry is refused.
- **Folders.** A grant can cover a folder ("Parent, medical"), so a group
  is shared without the vault.
- **Management.** The owner grants and revokes in the app. Agents only
  request (`ask_for_sign_in`). `SignIn::Use` records each use per agent and
  entry, and the owner sees it.
- **Crossing.** Never across workspaces, except the owner explicitly shares
  it, as a person who belongs to both.
- **Imports.** Owner-approved, item by item or folder by folder, logged.
  Never a bulk dump. Passbolt to Passbolt is a share, not a copy. Others
  (1Password, Bitwarden) are a later step through the owner's own export,
  read in the request, never stored outside the vault.
- **Secrets** never reach an agent's model, a log or a command's argv. This
  removes today's one exception: `ask_for_sign_in` passes the new password
  as a CLI argument.
- **Security answers** stay as custom fields on the entry, with the same rules.

Built first: a workspace's own Passbolt user (`Workspace::VaultUser`,
migration 20261117010000, its key and passphrase encrypted on the workspace),
set by its owner on its page. Every use of the vault for an agent takes the
first whole pair of the agent's own, its workspace's and the install's
(`DurableAssistants::Passbolt.key_for`), so a workspace with its own user never
reads the install's folders, and another workspace's agent never runs as it
(`CrossWorkspaceSecretsTest`). Grants checked by Rails, folders, uses and
imports are still to come.

## 3. Crossing between workspaces

Two ways, both explicit and visible:

1. **A person in both.** Someone who belongs to two workspaces can read and
   act in each, and can carry something across themselves. Agents never do
   this on their behalf without their yes.
2. **A bridge.** `Workspace::Bridge` (agent, outside network, approved by)
   lets one agent speak on an outside network. An agent may hold **many**
   approved bridges, each to a separate outside network, gained over time. A
   manager approves each, and each crossing is recorded. It carries words,
   never credentials, sign-ins or files. Third-party content needs the
   owner's yes before it crosses (the existing original-source rule).
   Content never crosses **between** two outside networks an agent bridges
   without its own explicit, approved and logged step: a message from
   network A is never readable or forwardable into network B otherwise. Test:
   one agent with two outside bridges; a message from A cannot reach B
   without that step, and with it, the step is logged.
   Built (step 2b) without a further step: a reply or a read is on its
   task's network (`Tool::ConcourseCalls#network_of`), and the only way
   anything reaches a bridge is a `concourse_send` a person approved, which
   the ledger records (`Invocation`, its approval). Tested in
   `test/models/tool/concourse_test.rb`.

Never: one ordinary agent in two workspaces, a connector, key or sign-in
reaching across, or a Campfire room or wiki collection shared by two.

Today's rules fit as follows:
- A company network stays in its own workspace. Its bridge is the one
  designated agent.
- Outside pilots are outside networks: untrusted mail, sends approved.
- Nothing crosses without the owner's yes.

## 4. Mapping an install

The install's own mapping (which agents go where) lives with the install,
not here. In general:
- **Each world becomes a workspace:** the owner's team, each company, each
  outside pilot, the household and the family.
- **What moves:** agents' workspace assignment; per-workspace Campfire
  rooms or a Campfire; wiki collections and keys; Concourse joins beyond a
  workspace's home network become bridges or are retired; Passbolt folders
  become workspace-owned grants.
- **What stays:** agents, threads, history, notes, computers, models,
  addresses and phone numbers. No thread is copied or merged.

## 5. Decisions

The owner approved 1–6 as recommended, in the order of 6, with one change:
an agent may hold many approved, logged bridges, each to a separate outside
network, with nothing crossing between them unapproved (section 3). Several
computers are an install setting, off by default (section 2.5). Sharing stays
off for each workspace until it knows who pays.

1. **A workspace is the boundary, and an agent belongs to exactly one.**
   Recommend: yes. It replaces per-agent sharing (#40 decision 2).
2. **Campfire per workspace, or shared with closed rooms?** Recommend: shared
   for workspaces whose people trust one another (team, household, family);
   a separate Campfire for anyone outside (companies, pilots).
3. **Per-workspace wiki key, with Outline groups and collections.**
   Recommend: yes. The install-wide key remains only for single-workspace
   installs.
4. **Agents with a second Concourse identity become bridges.** Recommend:
   yes. A bridge is approved per pair of workspaces and logged.
5. **Saved sign-ins granted in the app, checked by Rails at each use.**
   Recommend: yes, Passbolt-to-Passbolt sharing first. Imports from
   1Password and Bitwarden come later.
6. **Order.** Recommend: multi-computer first (it stands alone), then
   `Workspace` with memberships and the payer resolver (#41), then chat,
   wiki and Concourse scoping, then sign-in grants. Sharing stays off until
   each workspace knows who pays.