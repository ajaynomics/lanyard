# Who contacts whom in a workspace

Two rules a shared workspace keeps on its members page (`/workspaces/:id`),
for its own agents only. Another workspace's agents are not bound by them,
even when they write to the same people.

## Only one agent contacts a member

A member may name one of the workspace's agents under **Who contacts you**:
"Only this agent contacts me". From then on no other agent of the workspace
reaches them by address or number (`Workspace::Membership#sole_contact`):

- `send_email` to their email, in To, Cc or Bcc; `send_text` to their number;
  `imessage_send` to a chat with them alone; a Gmail connector's
  `send_message` to their email; `calendar_save_event` inviting them. Each is
  refused before anyone is asked, and again when an approved call would go,
  even where the install approves everything. The agent is told whom to go
  through: "Quinn hears only from Ada in Harbour, so nothing was sent. Go
  through Ada instead."
- A card waiting on the workspace's people is not mailed to them by another
  agent. Their devices still get its notification, and the card waits in the
  app, as for any member.

The named agent sends as before, under the usual approvals. Setting it back
to "Any of its agents" lifts the rule; deleting the agent does too.

The app knows a person by their email. **My mobile number** is the number
texts are checked against; the app knows no other number for a person.

Not covered: a Telegram message (a chat id names nobody's address), an
iMessage group chat (its people are only names here), a Gmail draft sent by
its id (`send_draft`), and Concourse. A Concourse task is addressed to an
agent's handle and carries only the calling agent, never a person it is
for, so mail "for" a member cannot be told from mail for the agent, and is
not rerouted.

## Contact routing

**Contact routing** lists outside contacts, each an email address or a
ten-digit number, with the agent that answers them
(`Workspace::ContactRoute`). Its owner adds and removes them; every member
sees the list.

Mail from a routed contact to any of the workspace's agents, or a text from
a routed number (voip.ms forwards texts as mail, `docs/phone.md`), reaches
the routed agent alone. The agent it was sent to is not woken. The message
says so: "Sent to bo@…, the address of Bo; routed here by the workspace's
contact routing." Sent to several of the workspace's agents, it arrives once.
The routed agent answers from its own address or number.

Routing follows the sender's address or number, which mail can forge; the
routed agent still treats it as untrusted mail, and anything it sends still
asks as usual. Mail found in a mailbox an agent only reads
(`docs/email.md`, "Read-only mailboxes") stays with that agent. Routing comes
after an agent's mail passes to the one that replaced it (`docs/email.md`,
"When one agent replaces another").
