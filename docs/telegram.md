# Telegram

An agent can be a Telegram bot. What people write to the bot directly, and
what is said to it in groups the bot is in, reaches the agent's thread as
untrusted messages, the way mail and Campfire's do. The agent answers with
`telegram_send`, and its person approves every message, or every message to
a chat they allowed "Always".

It needs the install's password manager (`docs/passwords.md`): the bot's token
lives there and nowhere else. No install setting is needed.

## Setting one up

1. In Telegram, make a bot with @BotFather and copy its token, like
   `123456789:AA…`.
2. Save the token in the password manager as an entry's password, with
   `api.telegram.org` as its address, and share the entry with the agent's
   Passbolt user (or the agents' shared one).
3. As the owner of the agent's workspace, open the agent's Channels and put
   the entry's name under Telegram, then Connect.

Connect reads the token from the vault, asks Telegram which bot it is
(`getMe`) and tells Telegram to post the bot's messages to the app
(`setWebhook`, messages only), with a new secret. Only if Telegram takes both
is the bot kept. Connect again after changing the token: the old secret stops
working. Disconnect tells Telegram to stop posting (`deleteWebhook`) and
forgets the bot; deleting the agent forgets it too, and Telegram's posts then
get 404 until it gives up.

Another member of the workspace uses the agent but never sees or changes its
bot.

### Groups

Add the bot to a group as you would a person. In a group, a post wakes the
agent only when it calls on the bot: it mentions the bot by its @name (or by
a link to it, which Telegram makes for a name typed from the member list), or
it is a reply to one of the bot's own posts. Every other post is stored, with
its sender, chat and time, but starts no turn: people talk among themselves
without the agent answering each line, and nobody has to move or delete
anything for it. A direct message always wakes it. The agent reads what it
was not called on with `telegram_messages` (below).

By default Telegram's privacy mode lets a bot see only messages that mention
it, answer it or are commands, and then those are all there is to store. For
the agent to hear a group whole, turn privacy mode off with @BotFather
(`/setprivacy`) before adding the bot, or make the bot an administrator of
the group.

## The token

The token is read from the vault for each call to Telegram and dropped after
it, as an own mail account's password is (`docs/email.md`). It is never in the
database, a log, a job's arguments or the password manager command's
arguments, and the agent never sees it: its vault entry is refused to
`sign_in_with_saved_password` and `call_api_with_saved_key`
(`Agent#reserved_sign_in?`), and is not listed to the agent. An entry saved for
another address, or whose password isn't a bot token, is never sent to
Telegram. The Bot API takes the token in the request's path, so no error the
app writes carries a URL.

## In: the webhook

Telegram posts each message to `POST /telegram/:id` with the bot's secret in
`X-Telegram-Bot-Api-Secret-Token`, compared in constant time; a wrong or
missing secret and an unknown bot both get 404 (`docs/open-routes.md`). It is
rate limited: 60 a minute per bot, 600 per address. The words are handled in
a job (`TelegramReceiveJob`), which keeps them out of the log.

A webhook rather than polling `getUpdates`: it is how the app already hears
Campfire and Concourse, a chat wants an answer in seconds rather than at the
next minute's sweep, and the vault is read only when there is something to
send or fetch, not every minute for every bot.

Every message Telegram posts is stored (`TelegramMessage`: the chat,
Telegram's message id, the sender's name, its words and when it was sent),
once however often Telegram posts it. The Bot API keeps no history a bot can
ask for later, so this is the agent's only record of what a group said while
it was not called on. It goes when the bot is disconnected or the agent
deleted.

A direct message, or a group's post that mentions or answers the bot (above),
also reaches the thread as from its sender in its chat: "Maya Reyes in
Weekend plans", or "Sam in a direct message", with its text or caption, and
the chat's id to answer with. Telegram's update id makes it arrive once,
however often Telegram posts it. Alone or in a group, a message goes by the
one rule for every channel (`docs/agent.md`, "The inbox: one rule for every channel"): from the agent's
own person, known by the name Telegram shows, it goes in at the agent's next
step; anyone else's waits in its inbox unless it opens with "urgent", "stop"
or "asap", after any mention of the bot. A message with no words and no
files (someone joined, a title changed) says nothing and is not stored.

### Files

A photo, document, audio, video, voice note or sticker is listed with its
name, type, size and file id ("Attached, not yet saved"); of a photo, only its
largest size. Nothing is fetched unasked. `telegram_file` saves one on the
agent's computer, in `~/files`, the way an iMessage attachment is
(`Tool::ImessageAttachment`): the call says what it is, and the sidecar
fetches the bytes from Telegram once more (`agent/files.mjs`), streamed
through a temporary file. Telegram's Bot API serves files up to 20 MB; a file
whose id has expired fails, saying so.

## Reading a chat: `telegram_messages`

Telegram's Bot API has no history call, so a bot can read only what it was
sent. `telegram_messages` searches the posts this bot kept (`TelegramMessage`),
woken or not, newest first: each post's words, sender, time and chat (id and
title). It narrows by chat (its id or title; every chat when left out), by
words (`query`, in any case) and by time (`since`, `until`), up to 50 at a
time, 20 unless asked. With no words, a chat's latest posts are what comes
back, so catching up on a group is one call. Nothing said before the bot was
connected, or that privacy mode kept from it, is there.

The bot's own messages are in the list too, marked `yours`, taken from the
send ledger (`Dispatch`): Telegram never echoes a bot its own messages, so
nothing else would show them. They are narrowed by the same chat, words and
time, and carry Telegram's id for each. One whose answer never came is marked
`unknown` and has no id until something reveals it (below), so the agent sees
here whether a message of its own arrived: there is one read tool, not two.

It reads only this agent's bot and this agent's sends: another agent's bot,
even in the same group, kept its own and its sends are its own, and a chat
this bot is not in is refused. Reading asks no one. It is looked up
(`tool_search`), not declared, so it adds nothing to an agent's
tool count.

## Out: `telegram_send`

`telegram_send` takes a chat's id and the text (up to 4,096 characters, as one
message). The person approves every send, with the chat's name and the exact
words, even where the install allows or approves everything
(`APP__APPROVALS=allow`, `APP__APPROVE_EVERYTHING`), unless they answered
**Always for this chat** on an earlier card. That covers that one chat only,
and is listed and removable on the agent's Permissions page and under its
Telegram setting; there is no
"Always" for every chat ([Permissions](permissions.md#always-with-exact-recipients)).
Declined, nothing is sent.

### When Telegram doesn't answer

Each send is recorded (`Dispatch`) before Telegram is asked, as a text or an
email is (`docs/phone.md`, `docs/email.md`): Telegram can take a message and
never answer, and a call that only remembered its answer would not know
whether it sent.

- A send Telegram refuses (the person blocked the bot, the chat isn't there,
  any 4xx) says why and that nothing was sent; so does one that never reached
  Telegram, and a vault entry that can't be read. Nothing went.
- A send whose answer never came — a dropped connection, a read timeout,
  Telegram's own error — is **unknown**, never failed: "it may have gone;
  read `telegram_messages` for this chat". The app never sends it again on its
  own, nor after a crash (`Invocation::RUN_LIMIT`), and the same words to the
  same chat again are refused while it is unknown.
- Nothing can be asked: the Bot API lists nothing a bot has sent. So an
  unknown send waits for one of two things. A later post that quotes it —
  a reply carries the message it answers whole, with Telegram's id for it —
  marks it sent, matched conservatively by the same chat and the same words,
  against the oldest send still waiting and no other. Failing that, a person
  who looked at the chat says on its card whether it went.

`telegram_send` and `telegram_file` are declared only for an agent with a bot
where it can read the vault, so other agents keep their tool count;
`telegram_messages` is looked up (`tool_search`), so reading costs
no agent a declared tool.
