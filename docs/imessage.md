# iMessage

An agent can find, read and send iMessages on its person's own phone, through
a [BlueBubbles](https://bluebubbles.app) server on their Mac. It is the
install owner's own messages, so it is per install: one Mac, or none.
Nothing comes in: new iMessages don't reach an agent by themselves; it reads
a chat when asked. Pictures, reactions and replies to a bubble are not built.

## Setting it up

1. **The server.** On the Mac signed in to the person's Apple ID, install
   BlueBubbles Server (1.9 or later), set a server password, and keep it
   running. The install must reach the Mac's port: on the same network, its
   local address, as `http://192.0.2.20:1234`.
2. **The install.** Put the address and password in the install's secrets as
   `BLUEBUBBLES__URL` and `BLUEBUBBLES__PASSWORD`. Tool calls run in the
   install's `job` role, so check that container reaches the address, not
   only the web one.
3. **Each agent.** In the agent's Tools, under Built in, switch on what it may
   do: iMessage chats, iMessage history, iMessage send. They are off for
   every agent until switched on, and reading can be on without sending.

## What the app allows

- **Three tools.** `imessage_chats` finds chats by a name, number or address,
  named from the Mac's contacts, each with its GUID. `imessage_history` reads
  one chat a page at a time, newest first; what others wrote is marked as
  theirs. `imessage_send` sends one or more bubbles, in order, into one chat.
- **The person approves every send,** even where the install allows
  everything (`APP__APPROVALS=allow`), unless it approves everything
  (`APP__APPROVE_EVERYTHING=true`), and is never offered "Always": it goes
  out in their name, to people they know (`Tool.asks every_time: true`). The
  card shows the chat's name and people, as `imessage_chats` last listed
  them, and every bubble whole; a group the agent never looked up says so.
- **What arrived.** After sending, it watches the chat for a few seconds and
  reports each bubble delivered, or sent: an SMS never reports delivery.
- **Never twice.** A send BlueBubbles didn't confirm (a timeout, an error
  after it may have gone) fails the call as "may or may not have gone", with
  what went before it, and tells the agent to read the chat and tell the
  person. One Messages refused while finding the chat (AppleScript's -1700 or
  -1728, after both of BlueBubbles' scripts failed) is reported as not sent,
  with why. A call made again after a crash first reads the chat and skips
  each bubble that already went.
- **The record.** Every send is in the thread as its tool call: who approved
  it and when, the chat, the exact words, and what happened to each bubble.

## The password

BlueBubbles' password opens every message on the Mac, and BlueBubbles takes it
only in a URL's query string. So:

- Only `lib/durable_assistants/bluebubbles.rb` holds it. It asks for chats,
  messages, contacts and sending one text, and nothing else; no error it
  raises repeats a URL, a response body or the error's own message.
  `test/lib/bluebubbles_test.rb` holds that.
- It never reaches an agent's computer or the sidecar. The agent sees GUIDs,
  names, numbers and words, never the address or the password.
