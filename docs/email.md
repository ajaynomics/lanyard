# Email

Every agent has an address, `<email name>@MAIL__DOMAIN`, made from its name
when it is made (`travel@example.com`) and changed on its settings page. Mail to
that address reaches the agent's thread; the agent answers with `send_email`.
Without `MAIL__DOMAIN` and `MAIL__SMTP_ADDRESS` nothing here is on: agents
have no address and no tool.

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

A third channel, a Campfire room say, is one more of each. A routine
(`Routine`) comes in the same way, from the agent's own schedule, marked as
trusted since the person approved it.

## In: one catch-all mailbox

Mail for the whole domain lands in one mailbox (a catch-all) the install
already has. `EmailFetchJob` reads it over IMAP with TLS every minute and
hands each new message to Action Mailbox, which keeps the original and routes
it to `AgentsMailbox`. That finds the agents it names, in To, Cc, or, for a
blind copy, `Delivered-To` / `X-Original-To`, and delivers the text (an HTML
message as plain text; attachments are left out). Mail that names no agent is
left alone, and the job only reads the box: it marks nothing and deletes
nothing. Where it got to is kept in the cache; lost, it reads the box again
and Action Mailbox drops what it already has. Action Mailbox deletes its
copies 30 days after they are processed.

Rails has no IMAP ingress, so this job is it. A host that can pipe mail to a
command could use Action Mailbox's relay ingress instead; nothing else would
change.

Anyone can write to an agent. Their mail is marked untrusted, but it still
makes the agent run, at the model's cost.

## Out: SMTP

`send_email` sends from the agent's address, with its name, through the
install's SMTP server (STARTTLS, `MAIL__SMTP_*`). Mail to people on
`ACCESS__EMAILS` goes at once; mail to anyone else waits for the person to
approve that exact message. A reply carries `In-Reply-To` and `References`, so
it stays in the sender's thread. Tests never send: Action Mailer's test
delivery holds the messages.

## Settings

| Setting | |
|---|---|
| `MAIL__DOMAIN` | The agents' domain. |
| `MAIL__SMTP_ADDRESS`, `MAIL__SMTP_PORT` (587), `MAIL__SMTP_USER_NAME`, `MAIL__SMTP_PASSWORD` | Where mail goes out. |
| `MAIL__IMAP_ADDRESS`, `MAIL__IMAP_PORT` (993), `MAIL__IMAP_USER_NAME`, `MAIL__IMAP_PASSWORD` | The catch-all mailbox. Without it agents send but do not receive. |

The job role runs the fetch; set them on web and job.
