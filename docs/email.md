# Email

Every agent has an address, `<email name>@MAIL__DOMAIN`, made from its name
when it is made (`travel@example.com`) and changed on its settings page. Mail to
that address reaches the agent's thread; the agent answers with `send_email`.
Without `MAIL__DOMAIN` and `MAIL__SMTP_ADDRESS` nothing here is on: agents
have no address and no tool, save one with its own mail account (below).

## Channels

Email is the second channel, after Concourse. A channel is two small pieces:

- **In:** a class that calls `agent.conversation.receive(text, from:, via:,
  answer:, request_id:)`. The message reaches the thread marked with who sent
  it and how, as untrusted, never as the person's instructions, and with
  `answer`, how to reply through the same channel. `request_id` is stable for
  the message, so a repeat delivers once. `ConcourseAgent` and `AgentsMailbox`
  are the two today.
- **Out:** a tool the agent calls to answer (`concourse_reply`,
  `send_email`), with the approval rules of any tool.

While the agent is paused, what a channel brings in is held, unsent, and
read in order when it is resumed (`docs/agent.md`, "Pausing an agent"). A
Concourse task is told the agent is paused, as working; dropping a held one
rejects it. A held email or Campfire message dropped is only logged: no mail
or post goes out.

`current_time` with `received_since` answers "what have I received" for
every channel at once, from the agent's own thread (issue #43): per channel
(Email, Concourse, Campfire, Text) a count since then or `none`, `not
connected` for one it lacks, `unverified/N` when Concourse's or an own
mailbox's last check failed, the time it is checked through and what it
can't see yet, each sender marked untrusted, never their words. Email names
the boxes read for the agent: its own and the install's, or only its own
where that is its only address. Nothing knows of mail waiting in a box, so it
says only when each was last read, never that mail is "still in" one. Each message carries its id (an email its subject too), and
`current_time` with `read_received` and that id gives the whole message
again, as it reached the thread and still marked untrusted, only from the
agent's own thread: mail that arrived just before a summary of earlier
messages is still there to read. It is folded into `current_time` so no agent
gains a tool.

A third channel, a Campfire room say, is one more of each. A routine
(`Routine`) comes in the same way, from the agent's own schedule, marked as
trusted since the person approved it.

## In: one catch-all mailbox

An agent with its own mail account may also read its own inbox (below).
Mail for the whole domain lands in one mailbox (a catch-all) the install
already has. `CatchAllFetchJob` reads it over IMAP with TLS, the moment a
message lands and once a minute besides ("How soon it arrives"), and hands
each new message to Action Mailbox, which keeps the original and routes
it to `AgentsMailbox`. That finds the agents it names, in To, Cc, or, for a
blind copy, `Delivered-To` / `X-Original-To`, and delivers the text (an HTML
message as plain text; its files are saved and listed, below). Mail that names no agent is
left alone, and the job only reads the box: it marks nothing and deletes
nothing. Where it got to is kept in the cache; lost, it reads the box again
and Action Mailbox drops what it already has. Action Mailbox deletes its
copies 30 days after they are processed.

Rails has no IMAP ingress, so this job is it. A host that can pipe mail to a
command could use Action Mailbox's relay ingress instead; nothing else would
change.

## How soon it arrives

In seconds. Every box the install reads — the catch-all, each agent's own
inbox and each workspace's own catch-all — has a connection held open on it
that asks its server to say the moment a message lands (IMAP IDLE, RFC
2177). When the server says so, that box's own read is queued at once
(`MailIdler`). Texts come the same way, forwarded as mail.

`EmailFetchJob` still queues a read of every box once a minute, and that
minute is the net underneath: a server that does not offer IDLE, a
connection dropped without a word, or an idler not running leaves a box no
more than a minute behind, as every box was before. A read already running
when a message lands finishes and the next read takes it, so the slowest
case is still the minute.

The connections live in the job role's mail worker (`config/queue.yml`),
which also reads the boxes and routes what they held, so neither waits
behind the minute's sweeps. That worker is one process, so an install has
one idler, and the job role runs `bin/jobs` as before: no install changes
anything to get this. Nothing is configurable; there is no setting.

A connection is made again, waiting longer each time up to five minutes,
after it drops, and IDLE is asked for again every 25 minutes, inside the
half hour RFC 2177 allows, so no server drops a watcher that outstayed its
welcome. Every fresh connection reads the box first, since a message may
have landed while nobody was watching. A box added or taken away is picked
up within half a minute. Watching never reads a message: it only asks for
the read that has always read that box, one read of a box at a time.

What the agent reads, from any box, starts with the message's Subject, Date
and To, then Cc and Reply-To where it has them, so it copies no one twice
and replies where the sender asked (`ReceivedMail`). Mail that reached it with
none of its addresses in To or Cc came as a blind copy, and says
`Bcc: <its address>`: the catch-all found it by its envelope, its own box
holds only its account's mail. Nobody else's Bcc arrives, so none is shown;
a mailbox it only reads shows no Bcc line. A header a message lacks is left out.

Anyone can write to an agent. Their mail is marked untrusted, but it still
makes the agent run, at the model's cost.

Mail from a person, here or in the agent's own inbox, waits for the agent's
turn to end, or until it takes it in sooner; it is told at its next step that
mail waits (`docs/agent.md`, "The inbox: one rule for every channel"). Mail that can't
wait steers, read at the agent's next step: marked urgent, opening with
"urgent", "stop" or "asap", or from the agent's own person: the one rule every
channel follows. Automated mail waits for the turn
to end, and is never urgent: an `Auto-Submitted` header other than `no`, `Precedence` bulk, junk,
list or auto_reply, `X-Autoreply`, `X-Autorespond` or `List-Id`, an empty
`Return-Path`, a delivery report (`multipart/report`), or a no-reply,
mailer-daemon or postmaster sender (`ReceivedMail::Automated`). So does
mail found in a mailbox it only reads.

## Attachments

A file someone mails an agent reaches its computer, whichever box the mail
came through: the install's, its own or a read-only one (`ReceivedMail::Files`).
Every attachment counts, and so does a picture the message's body shows, an
inline part with a name or a `Content-ID`; one with no name is named by its
`Content-ID` (`logo.png`).

- **Saved as a tool's file is.** The files are held on a ledger row of the
  mail's own (`Invocation#hold_file`, task `email`), and Rails asks the
  sidecar to save them (`POST /v1/conversations/:id/files`). It fetches each
  back by its place (`POST /agent/files`, inside the host only, within ten
  minutes) and writes it under `~/files/<folder>/` with its own name, a PDF's
  words beside it, as it does a Gmail attachment (`agent/files.mjs`).
- **What the agent reads.** Above the message's words, a list: each file's
  name, type, size and where it was saved, or "not saved" and why:

  ```
  Attachments:
  - Extract.pdf (application/pdf, 39.1 KB): saved at /home/agent/files/0a1b2c3d4e/Extract.pdf; its words are in /home/agent/files/0a1b2c3d4e/Extract.pdf.txt
  - logo.png (image/png, 508 Bytes): not saved: you have no computer here to save it on.
  ```

- **No size limit.** Nothing is cut. A file is refused only by a computer
  without room for it, which says how much it needs and has.
- **When it can't be saved.** An agent with no computer of this app's (a
  Sprite), a computer an operator holds, or one that can't be reached: each
  file is listed as not saved, saying so, and the mail still arrives.
- **Once.** What was said of each file is kept on the row, so the same
  message read again (from two boxes, or a retry) is listed the same and its
  files are not saved twice. The bytes are kept only until the sidecar may no
  longer fetch them.

## When one agent replaces another

Mail to the old agent's address can go to the agent that replaced it, so
people who still write to the old address reach the new one. There is no
screen for it; in a console:

```ruby
old.update!(mail_to_agent: new)   # mail to old's address now reaches new
old.update!(mail_to_agent: nil)   # undo: old has its own mail again
```

- The old agent is never woken by it, and an archived one stays archived.
  The new agent's thread comes back from the archive as it does for any mail.
- The message says where it was sent: "Sent to old@…, the address of Old,
  which now comes to you." The old address may be only in a blind copy's
  envelope, so this line is how the new agent knows.
- It goes one step. Both agents must be the same person's, the new one may
  not pass its mail on, and nothing may pass mail to an agent that does.
  Mail from either agent's own address to the old one is dropped.
- Delete the old agent and its address is free, and nothing forwards. Delete
  the new one and mail goes back to the old agent, which then wakes for it.
- A text forwarded as mail (docs/phone.md) follows too, but the new agent
  answers from its own number, or says it has none. Move the old agent's phone
  number to the new one when one replaces the other.

## Routed by the workspace

A workspace's owner may route an outside contact to one of its agents: their
mail to any agent of the workspace reaches that one alone, saying it was
routed there. A member may also name the one agent that alone mails them.
Both are in `docs/contacts.md`.

## Out: SMTP

`send_email` sends from the agent's address, with its name, through the
install's SMTP server (STARTTLS, `MAIL__SMTP_*`). Mail to people on
`ACCESS__EMAILS` goes at once; mail to anyone else waits for the person to
approve that exact message. A reply carries `In-Reply-To` and `References`, so
it stays in the sender's thread. The agent may copy others, in `cc` (seen by
every recipient) and `bcc` (unseen), up to 10 addresses each as for `to`.
Every one of them counts as a recipient: the card shows To, Cc and Bcc, one
outside address in any of them makes the message wait, an Always for one
recipient never covers another added beside it, and an outside address in
any of them holds the message for the agent's sending hours. On the agent's [Permissions](permissions.md)
page, **Ask before every email** makes even mail to an admitted person ask
every time, regardless of the install's approval policy, unless the person
answered **Always with** every one of its recipients; there is then no Always
for every email ([Permissions](permissions.md#always-with-exact-recipients)).
The switch starts off.

Files from the agent's computer go too (`attachments`, up to 10 paths): the
sidecar reads them before the call, refusing a missing file, a folder, or one
over the limits, and sending nothing. Where the person approves, the card
names each file and its size and the approval holds to their bytes: a file
changed before it goes voids the approval, and the card asks again. Tests never send: Action Mailer's test
delivery holds the messages.

## Its own mail account

An agent may send from a mailbox of its own elsewhere (`desk@example.com` at
some mail provider) instead of its address here, and read its inbox (#77).
On the agent's Channels, **Mail account** names the address, an optional
name to show (the agent's by default), the SMTP server and port (587 by
default), the incoming (IMAP) server and port (993 by default), and the
name of a saved sign-in in the password manager holding the mailbox's
username and password. There is no password field: as for a linked calendar
(`docs/calendar.md`), the password stays in the vault.

- **Who sets it.** Only the owner of the agent's workspace sees the section or
  changes it; to another member it is not there, and its address answers 404.
  It is offered only where the agent can reach the password manager
  (`docs/passwords.md`).
- **Sending.** With the account, `send_email` goes from that address through
  that server: TLS from the start on port 465, STARTTLS (required) on any
  other. The username and password are read from the vault, as the agent,
  for each message and passed to Action Mailer for that message alone
  (`delivery_method_options`); the install's SMTP settings never change.
  The saved sign-in must name the SMTP server as its address, or nothing is
  sent: a password shared with the agent for one site never goes to another.
  The password is never stored in Rails, shown to the agent or the model,
  written to the ledger or logged.
- **Without it**, or where the password manager is not set up, mail goes as
  above. An agent with an account has `send_email` even where the install has
  no email.
- **Approvals are unchanged.** The same rules ask first, whichever way the
  mail goes.
- **Always Bcc.** One address the owner sets that gets a blind copy of every
  message the agent sends with `send_email`, attachments and replies
  included, whichever way it goes. The mailer adds it, in the envelope and
  not in the headers the recipients read, beside any Bcc the agent set
  itself. `send_email`'s arguments are its whole schema
  (`additionalProperties: false`): nothing the agent passes can drop it, and
  the address is in no tool description, result or ledger row, so the agent
  neither sees nor changes it.
- **Not through it.** The notice that an agent needs its person
  (`AgentMailer#needs_you`) is the app writing, not the agent: it goes the
  install's way, from the agent's address here, without the Bcc, so it still
  arrives while the vault is down and its link into the thread stays with
  the workspace's people. Where its workspace has its own mail domain, it
  goes that domain's way instead (below).
- **Its inbox.** With an incoming server, the agent reads the account's
  INBOX over IMAP, TLS from the start (993 by default), the moment a message
  lands and once a minute besides: each new message reaches its thread
  alone, as untrusted mail from its sender, with the same way to reply
  (`send_email` with `in_reply_to`). Nothing in it is routed to the agents
  it names. A connection held open on the box says when a message lands
  ("How soon it arrives"), and `EmailFetchJob` queues the read, one per
  account (`MailAccountFetchJob`), never two at once for one account, so a
  slow or refusing server holds up no other. The box is only read: nothing
  is marked or deleted.
- **Its Sent folder.** With an incoming server, each message the mail server
  took through the account is then copied into its Sent folder over IMAP
  (APPEND), as the server sent it and marked read, as a mail program does:
  some servers file nothing sent over SMTP, so neither the person nor the
  look in Sent below would find it. Always, with no switch. The folder is
  the one the server marks `\Sent`, else one named Sent, Sent Items, Sent
  Messages or Sent Mail. A message the server refused, or whose answer never
  came, is not copied: the copy would vouch for it below. Nothing is copied
  for mail that goes the install's way or through a connector (Gmail's
  `send_message` is Gmail's own). Copying is after the mail went, so a copy
  that fails (no Sent folder, the sign-in or the server refusing, or the
  server not answering in time) fails nothing: the log names the account
  and the kind of error, and nothing else. A server that also files SMTP
  mail itself may then hold two copies (Gmail says to turn a mail program's
  copy off; whether it drops the second is not documented). The copy
  carries no Bcc line, as none was sent.
- **Where the password goes.** One saved sign-in serves both servers, so
  the incoming server must be the mail server itself or one beside it in
  the same domain: `imap.example.com` beside `smtp.example.com`, not
  `imap.elsewhere.example`, not `example.com`, and not `imap.com` beside
  `smtp.com`. The sign-in must name the mail server, as for sending. Both
  names are the owner's, typed on the form; the agent changes neither.
- **What is news.** Mail already in the box when it is first read is not:
  the first read starts at the newest message. After that it reads from the
  last message it took. A box whose UIDVALIDITY changed (renumbered by its
  server) is read again from the time of the last good read, and what the
  thread already had is dropped by its request id. Changing the incoming
  server, its port, the mail server or the saved sign-in starts afresh.
  Mail from the account's own address, from the agent's address here, or
  from the Always Bcc is skipped: copies of what it sent, or replies to its
  own copies, would wake it for nothing.
- **Once, whichever box.** A message's request id is the agent's and the
  message's (`email:<agent>:<Message-ID>`), the same from either box, so
  mail sent both to the account and to the agent's address here reaches the
  thread once.
- **When it can't read.** The vault unreachable, the sign-in missing or
  saved for another server, the server refusing it or unreachable: the
  reason is kept, in words of our own, never the server's or the password,
  and shown to the owner under Mail account. The log names only the
  account and the kind of error. It tries again the next minute from where
  it got to.

### Its only address

**Only address**, a switch under Mail account, off by default, makes the
account the agent's only address. Only the owner sets it, on the same form;
the agent cannot (`change_yourself` takes its instructions alone). While on:

- **Sending.** `send_email` goes from the account or not at all. Where the
  password manager can't be read, or the saved sign-in is missing or for
  another server, it refuses with the reason, before anything is held, and
  nothing goes from the agent's address here.
- **What it is told.** Its prompt names the account's address as its own,
  and never its address here. Its Channels and settings show the account's
  address.
- **In.** Mail to its address here, in the catch-all box, is turned away:
  not delivered to it, with one line in the log naming the agent and nothing
  of the message. The message is kept as any other. Mail to it that names
  another agent still reaches that one. An agent another has replaced and
  whose own account is its only address passes nothing on either. A text
  voip.ms forwards must go to the account's address, read by its inbox.
- **The notice that it needs its person** still goes from its address here,
  as above: it is internal mail to the owner only, never to anyone else,
  and must arrive while the vault is down. A reply to that notice is turned away like other mail there; the
  notice says to answer in the app.

Turned off, it uses both again, and the next mail to its address here
reaches it. Removing the account turns it off with it.

## A workspace's own mail domain

One install may host several workspaces, each its own world
(`docs/design/workspaces.md`). A workspace may have a mail domain of its own
(`field.example.net`) instead of `MAIL__DOMAIN` (#229). Its agents' addresses
are at it (`scout@field.example.net`), and its New agent form, Channels page
and `make_agent` card say so. Workspaces without one are unchanged.

The install's operator sets it, in a console, never the workspace's people:
mail for a domain is its owner's to route, and its people's to trust.

At the mail provider, a mailbox that exists for an address takes that
address's mail itself. Only mail to an address with no mailbox of its own
reaches the provider's catch-all. So the catch-all is where mail for every
agent without its own mailbox lands, and whoever reads it reads all of that.

1. Add the domain at the mail provider, and publish its MX, SPF and DKIM
   records, so mail for it reaches the provider and mail from it is trusted.
2. Leave in place any mailbox that is an agent's own (`desk@field.example.net`,
   its Mail account): it keeps taking its own mail before the catch-all.
3. Choose the catch-all mailbox.
   - **One agent in the workspace:** the provider's catch-all may point at
     that agent's own mailbox. The agent reads all stray mail there as part
     of its job, through its own inbox. The mail domain then only sends: set
     it without an incoming server (step 6, first form).
   - **More than one agent:** create a dedicated catch-all mailbox
     (`inbox@field.example.net`) that no agent owns, point the provider's
     catch-all at it, and let the mail domain read it (step 6, second form).
     Never use an agent's own mailbox: that agent would see every other
     agent's mail.
   - **If a second agent joins a workspace whose catch-all is an agent's own
     mailbox,** switch, all in one step: create `inbox@field.example.net`,
     point the provider's catch-all at it, and set it as the domain's reader
     (step 6, second form).
4. Save the sign-in the domain uses in the password manager, as the
   workspace (its own Passbolt user) or the install's, with the mail server
   (`mail.field.example.net`) as its address: the dedicated catch-all's, or,
   in the one-agent shape, a mailbox at the domain allowed to send for it.
5. Use that entry's name as the mail domain's `vault_entry`.
6. Set the mail domain in a console:

```ruby
workspace = Workspace.find(3)
# One agent: it only sends; the agent's own inbox reads the catch-all.
workspace.create_mail_domain!(domain: "field.example.net", smtp_host: "mail.field.example.net", vault_entry: "Field mail")
# More than one: it also reads the dedicated catch-all (inbox@field.example.net), whose sign-in "Field mail" is.
workspace.create_mail_domain!(domain: "field.example.net", smtp_host: "mail.field.example.net",
  vault_entry: "Field mail", imap_host: "mail.field.example.net")   # ports 587 and 993 by default
workspace.mail_domain.update!(imap_host: "mail.field.example.net", vault_entry: "Field mail")   # switching to the dedicated box
workspace.mail_domain.destroy   # the install's domain again
```

7. After a minute, `workspace.mail_domain.reload.inbox_error` is `nil`
   where it reads a catch-all.

- **Sending.** `send_email`, and the notice that an agent needs its person
  (`AgentMailer#needs_you`), go from the agent's address at the domain
  through the domain's server, signed in for each message with the saved
  sign-in the operator named: TLS from the start on port 465, STARTTLS
  (required) on any other, as for an agent's own account. It is read from the
  vault as the workspace (its own Passbolt user, else the install's), and
  must be saved for the mail server, or nothing is sent. The install's SMTP
  settings never change. An agent with its own mail account still sends
  through that. A notice whose sign-in can't be read (the vault down) is
  tried again every five minutes for an hour, never sent another way.
- **In.** Mail to an agent at its workspace's domain reaches it, from the
  install's catch-all box or the domain's own. With `imap_host`, the domain's
  catch-all box is read the moment a message lands, and each minute besides,
  with the same saved sign-in
  (`WorkspaceMailFetchJob`), and its mail routed by the address it names, as
  the install's is. What is in the box when it is first read is not news.
  Why a read failed is kept on `mail_domain.inbox_error`, in our words. The
  incoming server must be the mail server or one beside it, as for an
  agent's own account. Without `imap_host` the domain reads nothing and only
  sends.
- **Never an agent's own mailbox.** Before each read, the catch-all's user
  name, from its saved sign-in, is compared with every agent's own mailbox
  in the install, its read-only ones included: the same incoming server and
  the same user name (its address, or the user name its own saved sign-in
  holds), whatever their case or spaces, is the same box. Then the box is
  not read, `inbox_error` says so, and the log names only the workspace. The
  vault alone knows the user name, so this is checked at each read, not on
  save, and an agent's mail account is not checked against a catch-all when
  it is saved.
- **Invitations.** An invitation to the workspace comes from the domain, at
  the install's sender's name (`durable_assistants@field.example.net` for
  `APP__MAILER_FROM=durable_assistants@localhost`), through its server, as
  the notices do: a vault that can't be read is tried again for about an
  hour, never sent the install's way.
- **One agent per address.** An address's name (`scout`) is unique across the
  install, whatever the domain. Mail to it reaches its agent at its
  workspace's domain or the install's (so an address it had before still
  works), and nothing at another workspace's domain. A domain is one
  workspace's, never the install's own.
- **Moving an agent** to another workspace moves its address to that
  workspace's domain.
- **Approvals, Always Bcc and sending hours are unchanged.**

## Read-only mailboxes

When an agent takes over a colleague's work, the colleague's mailbox
(`old@example.com`) can become a second mailbox it reads and never writes
to. On the agent's Channels, below **Mail account**, **Read-only mailboxes**
lists each with its incoming server, its folders and, when the last read
failed, why; **Add a read-only mailbox** takes the address, the incoming
(IMAP) server and port (993), the name of a saved sign-in, and the folders
to read, by the server's own names (`INBOX, Sent, Drafts` unless changed).

- **Who sets it.** Only the workspace's owner, as for the mail account: to
  another member it is not there, and its addresses answer 404.
- **Nothing leaves it.** It has no mail server and no Always Bcc. `send_email`
  takes no sender, so mail goes only through the agent's own account
  (`Agent#mail_account`, never a read-only one) or the install's. Should one
  ever be about to send through a read-only mailbox, `AgentMailer` raises and
  `send_email` refuses, saying so. No tool drafts in it.
- **Nothing is written there.** Each folder is opened with EXAMINE and read
  with `BODY.PEEK[]`: nothing is selected, appended, flagged, moved or
  deleted.
- **What reaches the thread.** Each new message in each folder, as untrusted
  mail, headed with where it was found (`In old@example.com, Sent:`). Mail
  from the mailbox's own address is not skipped: its Sent is all its own,
  and it is what the agent took over. A reply goes from the agent's own
  address; a message the colleague sent is followed up with whom it went to.
  A message in two folders, or in two mailboxes, reaches the thread once, by
  its request id (`email:<agent>:<Message-ID>`).
- **Where it got to.** Each folder keeps its own UIDVALIDITY, last message
  and last good read (`Agent::MailAccount::Folder`); what is in a folder when
  it is first read is not news. Changing the server, the port or the saved
  sign-in starts afresh. The sending account keeps its own place, as before.
- **The password.** The saved sign-in must name the incoming server as its
  address. It is read from the vault for each read and goes nowhere else.
  Like every account's, it is never filled into a browser or used as a key
  (`Agent#reserved_sign_in?`).
- **When it can't read.** As for the inbox: the reason, in our words, under
  the mailbox on the Channels page, naming the folder a server refused (a
  folder it does not have, say). The folders before it are kept.

## When the mail server doesn't answer

A mail server can take a message and then never answer: the connection goes
quiet, or drops, after the message was sent. Reported failed, the agent would
send it again. So each message `send_email` sends now is recorded first
(`Dispatch`), with a Message-ID the app chooses, and sent under it
(`Tool::SendsMailOnce`). On a timeout or a dropped connection once the
server was reached, the app asks the one account the message went through
whether its Sent folder holds that Message-ID, and nothing else:

- **Its own mail account, with an incoming server:** its Sent folder (the
  one the server marks `\Sent`, else one named Sent, Sent Items, Sent
  Messages or Sent Mail) is opened read only and searched for that
  Message-ID alone (`Agent::MailAccount::SentFolder`). Nothing is fetched,
  marked or kept. The sign-in is the inbox's, with the same rules for where
  its password may go. A server that takes the connection and then says
  nothing is given up on: 10 seconds to connect and start TLS, then 20 for
  each answer (`DurableAssistants::Email`), for this look and for the copy
  above, so a send is never held up for good. Given up on, the folder
  counts as unread, never as not holding it.
  - **Found:** it went; the call says sent, as if the server had answered.
  - **Not found yet, or the folder can't be read:** the call ends
    "unknown", with the Message-ID, and the agent is told not to send it
    again. It is looked for in the background, two minutes on and then
    less often, and the agent is told in its thread once it is found.
    Not found an hour on, or the folder unreadable for a day, it is
    **still unknown**, never "not sent": a Sent folder holds only what its
    server chose to file there. The app's own copy ("Its Sent folder",
    above) is made only once the server answered, so it never settles one
    whose answer never came. The agent is told not to send it again and
    to ask its person.
- **Mail through the install's own server, or an account with no incoming
  server:** there is no Sent folder this app may read. The call ends
  "unknown: don't send it again" at once. The install's shared mailbox is
  never opened to find out.
- **Refused by the server, or never connected:** nothing was sent, and the
  call fails, as before.

Mail still unknown has a card in the thread, as a text does (docs/phone.md):
"Still unknown whether this email went. Check the Sent folder for
Message-ID <…>, or ask the recipient, then say." with **It went** and **It
didn't go**. Only a person ends it there, and the agent is told what they
said. A retry of the same message is refused, naming its Message-ID, while
it is being checked or still unknown, and for ten minutes after it went. Gmail's
`send_message` is sent once the same way, with the connector's own search of
its Sent for that Message-ID (`rfc822msgid:`, `in:sent`); Gmail may give a
message a Message-ID of its own, so missing there is never taken to mean not
sent either. Mail held for the sending hours, and Gmail's `send_draft`, are
not covered yet.

## Sending hours

The owner of an agent's workspace may give it sending hours on its Channels
page: a start, an end (24-hour `HH:MM`) and a time zone, such as 08:00 until
19:00 in America/Toronto. An end before the start runs past midnight. None
set, the agent sends at any hour, as before.

They hold only what leaves the install: `send_email` to anyone outside the
install's admitted people, through the install's server or the agent's own
mail account. Mail to the install's own people, and the Always Bcc that goes
with every message, are never held.

Outside the hours, a send that is allowed (by the person, or by an Always)
is not sent. It is kept as it was allowed (`HeldEmail`): the call returns at
once with `held` and `sendsAt`, the next start in that time zone, so the
agent can say when it goes. The thread shows the message, "Held until …",
and Don't send. Each minute a sweep (`HeldEmailSweepJob`) sends what is due,
through the same mailer, so the forced Bcc goes too. Hours changed
meanwhile are read again then: if they are closed it waits for the next
start. Stopped before then, it never goes. Either way the agent is told
once, and the card says how it ended. The message itself can't change while
it waits: its words are the allowed call's, and its files the bytes that
were allowed. To send something different, cancel it and let the agent send
again.

A send that was under way when the app stopped, with no word back after five
minutes, is never sent again: whether it went is unknown, and the agent is
told so.

## Settings

| Setting | |
|---|---|
| `MAIL__DOMAIN` | The agents' domain. |
| `MAIL__SMTP_ADDRESS`, `MAIL__SMTP_PORT` (587), `MAIL__SMTP_USER_NAME`, `MAIL__SMTP_PASSWORD` | Where mail goes out. |
| `MAIL__IMAP_ADDRESS`, `MAIL__IMAP_PORT` (993), `MAIL__IMAP_USER_NAME`, `MAIL__IMAP_PASSWORD` | The catch-all mailbox. Without it agents send but do not receive. |
| `MAIL__ATTACHMENT_LIMIT_MB` (10), `MAIL__ATTACHMENTS_LIMIT_MB` (20) | The most one attached file, and all of a message's files, may be. |

The job role runs the fetch; set them on web and job.
