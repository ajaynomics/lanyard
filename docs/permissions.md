# Permissions

An agent's **Permissions** page has five independent switches under
**Sending and instructions**:

- **Ask before every email** (`send_email`).
- **Ask before every text message** (`send_text`).
- **Ask before every iMessage** (`imessage_send`).
- **Also ask before Concourse messages** (`concourse_send`). This does not
  change replies on existing Concourse tasks (`concourse_reply`).
- **Ask before every change to its instructions** (`change_yourself`).

The four send switches start off and the instructions switch starts on, for
existing agents and new ones. On asks the person to
allow or deny each call, even where the install allows or approves everything
(`APP__APPROVALS=allow`, `APP__APPROVE_EVERYTHING`). A send's card shows the exact
recipients and words, and has **Allow once** and **Deny**, never **Always**
for every call. Email is the one exception, below. Email to an admitted
person asks too. An attached file's name and size appear on the card;
changing its bytes before sending voids that approval and asks again.

An old **Always** answer stays in the list, marked **not used** while its
switch is on, except email's **Always** with recipients. Off restores the tool's existing rules, including an applicable
old Always answer. Off does not mean automatic: iMessage normally still asks
every time, and email to people outside the install normally asks first.
The switches are checked when a call starts; they do not recall a send already
allowed or started.

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
  API call, a saved-password sign-in), and when it changes the agent itself
  (`Tool.changes_itself`: `change_yourself`, `remove_routine`). **Always**
  still covers what it covered. Anything else that would ask runs at once,
  except what asks every time.
- **Approve everything**: no call waits for a card.

Under every policy, what asks even where everything is approved still asks
(`Tool.asks` with `even_approving_everything:`, `McpServer::Google::EVERY_TIME`,
the switches above, a connector set to ask before every write), and an
**Always** with exact recipients is still the only thing that lets those
sends go unasked. Questions and sign-ins still wait. `Agent#allows?` is the
one place a call is decided, through its workspace's policy; the agent's
Permissions page says which policy it follows and whose it is.

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

Two sends that otherwise ask every time take an **Always** for exact
recipients, and never one for every call (#150, `Tool.always_with_recipients`):

- `send_email` with **Ask before every email** on. The card offers
  **Always with** each address in To, Cc and Bcc, named on the button.
- `telegram_send`, always. The card offers **Always for this chat** and says
  which chat it covers ("Telegram chat -100…").

The person grants it from the card; nothing else makes one. It covers a later
call only when every recipient of that call was granted: one more To, Cc or
Bcc, or another chat, brings the card back. This holds where the install
approves or allows everything too: these sends run unasked only under such an
**Always**, and ask otherwise. An **Always** for every call stored for either
tool (from before, or written by hand) is never honoured, and the agent's page
marks it **not used**. Each grant is one row on the agent's page, named by
its recipient ("With robin@example.com", "With Telegram chat -100…"), and
**Remove** makes the next such call ask again. The same rows, with the same
**Remove**, sit under **Ask before every email** and under Telegram on the
agent's Channels page, so neither setting hides a standing grant; one made
before the switch was turned on still counts. Text messages, iMessage and
Concourse sends under their switches still take no **Always** at all.

An unanswered card stays for the person to allow or deny, even after its
switch is turned off. Turning a switch off does not send a waiting message.

Above every switch and policy: a member of the workspace who named another
agent as their only contact is never sent to by this one. The call is refused
before any card, even where the install approves everything, and the agent is
told whom to go through (`docs/contacts.md`).
New calls follow the restored rules; files on a waiting call still have to
arrive and still need fresh approval if their bytes change.

Each choice belongs to one agent. It neither gives that agent a tool nor
switches an unavailable or disabled tool on. Campfire's rules are unchanged.
A connector's separate [Ask before every write](connectors.md#ask-before-every-write)
switch is unchanged too, including its stronger approval boundaries.

## Instructions

`change_yourself` always asks the person first and is never **Always**, so
on an ordinary install the switch changes nothing. Where the install allows or
approves everything, a change to the agent's instructions normally applies
at once; with **Ask before every change to its instructions** on, it waits
for the person instead. The card shows the whole new instructions, says the
agent is set to ask every time, and has **Allow once** and **Deny**. The
instructions change only when the person allows it; denied, they stay as they
were. The card lists the lines the change removes first, then the lines it
adds, then the whole new text, so a dropped safeguard is plain to see; the
phone and Watch cards show the same. Any old **Always** row for `change_yourself` is marked **not used**
while the switch is on.

## A workspace's shared instructions

A workspace has shared instructions that every one of its agents follows
beside its own (`docs/design/workspaces.md`). An agent proposes a change to them
through the same tool, `change_yourself` with `scope: "workspace"`, never a
tool of its own. That proposal always waits for the workspace's **owner**,
even where the install approves or allows everything, whatever the agent's
**Ask before every change to its instructions** says, and is never
**Always**. Its card, "Change <workspace>'s shared instructions?", lists the
lines it removes, then the lines it adds, then the whole text, and says only
the owner can allow it. Every member sees the card; a member who is not the
owner who presses **Allow once** is refused and the card keeps waiting
(`Invocation::NotTheApprover`); any member may deny it.

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

The five non-null columns on `agents` are `asks_every_email`,
`asks_every_text`, `asks_every_imessage` and `asks_every_concourse_send`
(default off) and `asks_every_instruction_change` (default on, for every
agent, those made before it too: an agent's own instructions are the one
thing a page it read could rewrite unseen). `Tool::AsksEverySend` applies the first four
to the call's approval policy, and `Tool::ChangeYourself` the fifth. A model
cannot change these person-owned settings through `change_yourself`: it takes
only the new instructions and their scope, and the switches are not part of them.
