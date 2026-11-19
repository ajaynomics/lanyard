# iMessage

An agent can find, read and send iMessages on its person's own phone, through
a [BlueBubbles](https://bluebubbles.app) server on their Mac. It is the
install owner's own messages, so it is per install: one Mac, or none.
Nothing comes in: new iMessages don't reach an agent by themselves; it reads
a chat when asked. It can save a photo or file someone sent; sending one,
reactions and replies to a bubble are not built.

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
   do: iMessage chats, iMessage history, iMessage attachment, iMessage send.
   They are off for every agent until switched on, and reading can be on
   without sending.

## What the app allows

- **Four tools.** `imessage_chats` finds chats by a name, number or address,
  named from the Mac's contacts, each with its GUID. `imessage_history` reads
  one chat a page at a time, newest first; what others wrote is marked as
  theirs, and each attachment comes with its GUID, name and type.
  `imessage_attachment` saves one attachment, by that GUID, on the agent's
  computer. `imessage_send` sends one or more bubbles, in order, into one chat.
- **Photos.** `imessage_attachment` works as Gmail's `get_attachment` does
  (`Invocation#file?`): the call answers with the file's name, type and size,
  and the sidecar then fetches its bytes from Rails once, soon after
  (`POST /agent/files`), and writes them under `~/files` on the computer
  (`agent/files.mjs`). The bytes never reach the ledger or the model. A HEIC
  or HEIF photo arrives as a JPEG, at full size and the right way up:
  BlueBubbles' download converts it on the Mac, so the agent's `read` can
  show it. Any size: Rails streams it through a temporary file, deleted once
  sent. Only an attachment's GUID is taken, never a path on the Mac.
- **The person approves every send,** even where the install allows
  everything (`APP__APPROVALS=allow`), unless its workspace approves
  everything (its own policy, or `APP__APPROVE_EVERYTHING=true` as the
  install's default, docs/permissions.md), and is never offered "Always": it goes
  out in their name, to people they know (`Tool.asks every_time: true`). The
  card shows the chat's name and people, as `imessage_chats` last listed
  them, and every bubble whole; a group the agent never looked up says so.
- **What arrived.** After sending, it watches the chat for a few seconds and
  reports each bubble delivered, or sent: an SMS never reports delivery.
- **Never twice.** Each send is recorded, with a key of its own
  (`Dispatch`, as texts are, `docs/phone.md`), before its first bubble goes.
  A bubble BlueBubbles didn't confirm (a timeout, an error after it may have
  gone) is looked for in the chat at once, among the person's own messages
  since the send began:
  - **There:** it went, and the next bubble goes.
  - **Not there yet:** the call stops and ends "unknown", with the key: that
    bubble marked unknown, those after it not sent, and the agent told not to
    send it again. The app looks again in the background, two minutes on and
    then less often, up to an hour apart, and tells the agent once the chat
    shows it. Not shown an hour on, or BlueBubbles not to be asked for a
    day, it stays unknown, never "not sent", which would invite a second
    send (and those before it again). Its card in the thread says so in one
    line, with **It went** and **It didn't go**, for the person to check the
    chat on the phone and say (`docs/phone.md` has the card).
  - One Messages refused while finding the chat (AppleScript's -1700 or
    -1728, after both of BlueBubbles' scripts failed) is reported as not
    sent, with why.

  A replay of the call sends nothing and looks in the chat instead. The same
  bubbles to the same chat are refused, naming the first, while it is being
  checked or went in the last 10 minutes, even after the person approved
  them again.
- **The record.** Every send is in the thread as its tool call: who approved
  it and when, the chat, the exact words, and what happened to each bubble.

## The password

BlueBubbles' password opens every message on the Mac, and BlueBubbles takes it
only in a URL's query string. So:

- Only `lib/durable_assistants/bluebubbles.rb` holds it. It asks for chats,
  messages, contacts, an attachment by its GUID and sending one text, and
  nothing else; no error it
  raises repeats a URL, a response body or the error's own message.
  `test/lib/bluebubbles_test.rb` holds that.
- It never reaches an agent's computer or the sidecar. The agent sees GUIDs,
  names, numbers and words, never the address or the password.
