# Permissions

An agent's **Permissions** page has four independent switches under
**Sending approvals**:

- **Ask before every email** (`send_email`).
- **Ask before every text message** (`send_text`).
- **Ask before every iMessage** (`imessage_send`).
- **Ask before every Concourse send**: a new task or continuation (`concourse_send`),
  or an answer to a linked inbound task (`concourse_reply`). Each card shows the resolved
  peer, network and exact text, and lets you allow it only once. If the route changes,
  nothing is sent. The rule also applies in code mode and to helpers. Incoming mail
  and the app's automatic notices about a paused or dropped task are unchanged.

The switches start off for all agents. On asks the person to allow or deny
each call, even where the install allows or approves everything
(`APP__APPROVALS=allow`, `APP__APPROVE_EVERYTHING`). A send's card shows the exact
recipients and words, and offers **Allow once** and **Deny**. It does not offer
or accept an **Always** while any applicable send switch is on. Email to an
admitted person asks too. An attached file's name and size appear on the
card; changing its bytes before sending voids that approval and asks again.

An old **Always** answer stays in the list, marked **not used** while its
switch is on. Turning every applicable switch off restores the tool's normal
rules, including applicable grants. Off does not mean automatic: iMessage
normally still asks every time, and email to people outside the install
normally asks first. The switches are checked when a call starts; they do
not recall a send already allowed or started.

## Workspace and install tool switches

Under **Tool switches** on a workspace's page, its owner can ask before every
send of one of the four kinds above or turn off named tools for all its
agents. The workspace's lists start empty. The install operator can set the
same restrictions, without a settings screen:

- `APP__DISABLED_TOOLS`: comma-separated tool names, such as `send_email,write_document`.
  Use the exact tool name for a connector's tool. These settings govern Rails
  tools, not sidecar abilities such as web search.
- `APP__ASKS_EVERY`: comma-separated names drawn from `send_email`, `send_text`,
  `imessage_send` and `concourse_send`. The last also covers `concourse_reply`;
  use only `concourse_send` in the list. An unsupported name fails the boot.

Blank lists add no restrictions. A tool is off or asks every time if any
level says so. The workspace cannot undo an install restriction, and an agent
cannot undo either. A locked switch names the workspace or install. The
agent's **Tools** page also switches `send_email` off for that agent alone
when it can send mail. These switches don't change the approval policy below.

## A workspace's approval policy

Each workspace has an **Approvals** row on its page (#226,
`Workspace::ApprovalPolicy`). Only its owner sees the choice and changes it,
a personal workspace's too; members read which policy applies, and anyone
else finds no such workspace. There are three choices, none stricter than
the normal policy: an owner may loosen their own workspace, or leave it to
the install.

- **Install's default** (blank, `workspaces.approval_policy` null): the
  install's settings, as before workspaces chose. `APP__APPROVE_EVERYTHING=true`
  is **Approve everything**; otherwise `APP__APPROVALS=allow` allows every
  call except what asks every time; otherwise every call that asks for
  approval asks, unless the person answered **Always**. Only an install
  chooses that last one; no workspace's owner can.
- **Ask before what reaches other people**, the normal policy: a call asks
  first when its tool reaches another person or account (`Tool.reaches_others`:
  email, texts, iMessage, Campfire, Concourse, calendar guests, a saved-key
  API call, a saved-password sign-in), and before it removes a routine.
  **Always** still covers what it covered. Anything else that would ask runs
  at once, except what asks every time. Own-instruction approval is separate.
  A Concourse send on a network the install names in
  `APP__INSIDE_CONCOURSE_NETWORKS` (comma-separated organizations, never
  across a bridge) stays inside and doesn't ask. Blank, every Concourse send
  asks.
- **Approve everything**: calls run without cards unless they always ask under
  the rules below.
  `APP__OWNER_APPROVAL_AGENTS`, comma-separated agent email names, makes the
  named agents approve everything whatever their workspace's policy. Core
  never asks on their behalf; give each one instructions for when to ask its
  owner by text or email. So a workspace set to **Ask before what reaches
  other people** shows cards for its other agents but none for a named one.
  Blank, the default, changes nothing.

Under every policy, what asks even where everything is approved still asks
(`Tool.asks` with `even_approving_everything:`, `McpServer::Google::EVERY_TIME`,
the send switches above, a connector set to ask before every write). Tools
that normally honour an exact-recipient grant still honour it unless a send
switch takes priority. Questions still wait. The agent's Permissions page
says which policy it follows and whose it is.

Payments, requests for sign-ins (in the app or via an outside link) and
saved-password sign-ins still show a card under every policy and never offer
**Always**. Payments are answered in Link. A saved-key API call shows a card
under every policy until the person answers **Always** for that key.

An install that wants some workspaces stricter than its default sets
`APP__APPROVE_EVERYTHING` or `APP__APPROVALS` for the rest, then has each
stricter workspace's owner choose on its page, or an operator set it once
after deploy:

```shell
bin/rails runner 'Workspace.find(ID).update!(approval_policy: "others")'
```

`ID` is the workspace's id, from its page's address. A new workspace starts
on the install's default.

## The agent's note to the approver

Every built-in tool that asks for approval takes one optional argument,
`note_to_approver` (at most 1,000 characters): what the agent wants the person
to know beside what it asks to do, such as their earlier words or questions
still open. The card shows it above the action, as "Note from <agent>", in
plain text with its line breaks, set apart from what is approved. It is taken
out before the tool runs, so it is never sent, saved or posted. It changes
nothing about whether a call asks or who an Always covers. The phone's sheet
for a card shows it too, as it is the same card; the Watch, notifications and
the Needs you list don't. A connector's tools don't take it. The note is stored
with the call's arguments, so the call's ledger digest covers it as it covers
every argument the sidecar sent. Allow binds the card the person saw, note
included: a run whose note differs from it is refused by that digest, and the
tool never acts.

## Always with exact recipients

Two tools can record an **Always** for exact recipients (#150,
`Tool.always_with_recipients`):

- The `send_email` card offers **Always with** each address in To, Cc and Bcc
  only while **Ask before every email** is off at every level. While any
  switch is on, the card won't save a new grant or honour an existing one.
- The `telegram_send` card offers **Always for this chat** and says which chat
  it covers ("Telegram chat -100…"). Its approval rules are unchanged.

The person grants it from the card; nothing else makes one. An applicable grant
covers a call only if every recipient matches: an extra To, Cc or Bcc address,
or a different chat, brings the card back under the normal policy. Grants stay
listed and removable in **Permissions**, under **Ask before every email**, or
under Telegram on **Channels**.

An unanswered card stays for the person to allow or deny, even after its
switch is turned off. Turning a switch off does not send a waiting message.

Above every switch and policy: a member of the workspace who named another
agent as their only contact is never sent to by this one. The call is refused
before any card, even where the install approves everything, and the agent is
told whom to go through (`docs/contacts.md`).
New calls follow the restored rules; files on a waiting call still have to
arrive and still need fresh approval if their bytes change.

Asking every time doesn't add a tool or switch an unavailable or disabled
tool on. Campfire's rules and the connector's separate
[Ask before every write](connectors.md#ask-before-every-write) are unchanged.

## Instructions

`change_yourself` asks before changing an agent's own instructions by default.
An install admin can choose **Ask** or **Don't ask** under **Own-instruction
approval** on Settings → Workspaces (the install), on a workspace's page, or
on an agent's Permissions page. The most specific explicit choice wins:
agent, then workspace, then install. An unset choice inherits, and every page
shows whether approval is required. **Don't ask** applies even under the
ordinary ask policy, to this tool and own instructions only.

When a call asks, the card offers **Allow once** and **Deny**. It lists the
removed lines, added lines, then the new text, each line whole and as plain
text. When the removed lines are more than half the old text, by characters,
it says "This removes a large part of the instructions.", and if the new text
is then longer than 1,000 characters it leaves the new text out: the added
lines are all of what is new. An old **Always** grant is not
used. Changing this setting does not settle a card that's already waiting.

Every proposal binds the saved text and revision, even when there is no card.
If the target, revision or access changes, ask for a new proposal:
**Allow once** never rebases it against the new text. A successful change
saves one revision, even if it is replayed. The revision keeps the tool call
and any approval. Pending cards from before this binding need a new proposal.

Prefer `edits`: a batch of 1–32 `{find, replace}` pairs, all against the same
saved instructions. Each `find` must match exactly once, even if matches
overlap. Two edits cannot touch the same character. An empty `replace`
deletes the match. Use `instructions` instead for a complete rewrite, not
alongside `edits`. A rewrite keeps the existing cleanup of generated identity
lines and workspace outer whitespace. Edits must already produce the exact
saved result with no cleanup. Text is limited to 32,768 characters per input
string and in the final result; edit text totals at most 65,536 characters.
A full rewrite still asks, whatever its size or content; nothing about it is
refused. History keeps every version, so any change can be undone. Above
12,000 characters the card and the call's result suggest deleting one line
for each line added; that warning does not block saving.
A small card can be allowed from the Watch; a longer one must be reviewed on
the phone.

## A workspace's shared instructions

A workspace has shared instructions that every one of its agents follows
beside its own (`docs/design/workspaces.md`). An agent proposes a change to them
through the same tool, `change_yourself` with `scope: "workspace"`, never a
tool of its own. That proposal always waits for the workspace's **owner**,
even where the install approves or allows everything or own-instruction approval
is off. It is never **Always**. Its card, "Change <workspace>'s shared instructions?", lists the
lines it removes, then the lines it adds, then the whole text, and says only
the owner can allow it. Every member sees the card; a member who is not the
owner who presses **Allow once** is refused and the card keeps waiting
(`Invocation::NotTheApprover`); any member may deny it. Changing the owner or
moving the agent invalidates the old proposal.

### Restore an approved revision

From **Review approved revisions**, a signed-in workspace member can review
the change for one of its agents' personal instructions. Only
the workspace owner can review or restore its shared instructions. Confirm
the preview within 15 minutes. If the target, current revision, or your
access changes, review it again. The same review cannot be used twice.

Restoring changes only the instructions and appends one revision. It records
both the original approval and who confirmed the restore. Only revisions
linked to a successful, human-approved instruction tool call in the same
scope are eligible. Unasked changes, older snapshots, direct edits, and
accepted member proposals without that approval link stay in history; none
is relabelled. Approval links from another workspace or an imported install
do not count. A revision keeps the fingerprint of the text its approval
covered, so it stays restorable after the call's own record is pruned.

## A workspace's tools

Six tools do through an agent what the workspace pages do, with the same
model methods (`Tool::WorkspaceCalls`): `list_workspaces`, `make_workspace`,
`rename_workspace`, `invite_to_workspace`, `change_workspace_member` (remove a
member, cancel an invitation or make a member the owner) and `move_agent`.
Each is picked one by one in an agent's Tools; no starter has them, so no
agent's tool count rises unless a person adds them. A catalogue tool can't be
looked up rather than carried yet, so each one picked counts towards the 64.

They act for the owner of the agent's workspace, and only she answers their
cards; anyone else's **Allow once** is refused, and any member may deny.
`make_workspace` and `rename_workspace` ask every time, never **Always**.
`invite_to_workspace`, `change_workspace_member` and `move_agent` change who
reaches what, so they ask even where the install approves or allows
everything. Denied, nothing changes.

Everyone in a workspace reads what its agent says, so an agent names only
what they all may know: in its person's own workspace, every workspace of
hers; in a shared one, that one alone. Any other name, or a change she could
not make on the pages (inviting to a workspace she doesn't own, moving an
agent of a workspace she doesn't own), is refused before any card. Only the
owner of a workspace sees its invitations through `list_workspaces`, and only
from her own workspace.

## Columns

The four send switches are non-null `agents.asks_every_*` booleans (default
off), applied by `Tool::AsksEverySend`. Agents and workspaces both have a
nullable `own_instruction_approval`; the install's choice lives in the shared
storage volume at `storage/own_instruction_approval` and is included in its
file backup. All choices start unset, including for existing agents. The old
agent flag stays in the database for rolling deploys but is not read by the
new release. Its Off meant follow the ordinary policy, not run unasked. The
model cannot set any of these choices through the tool.
