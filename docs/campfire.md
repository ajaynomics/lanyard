# Campfire

An agent can be a Campfire bot: the third channel, after Concourse and email
(`docs/email.md` describes the seam). Campfire is the office's chat
(`docs/office.md`); the app reaches it inside the host, or at `CAMPFIRE__URL`
for one somewhere else.

## Setting one up

With `CAMPFIRE__ADMIN_EMAIL` and `CAMPFIRE__ADMIN_PASSWORD`, a Campfire
administrator's sign-in, every new agent becomes a bot as it is made, in a
job, so a Campfire that is down or has changed never stops an agent being
made; until then, and for agents made before, the Channels page has "Make
<agent> a bot". The app signs in through Campfire's own sign-in form, adds a bot named for the
agent with its webhook address, and reads the bot's key from the bots page. The bot joins every open room, such as All Talk. "New webhook
address" tells Campfire the new one; Disconnect, or deleting the agent,
deactivates the bot, so it leaves every room and its key stops working.

Stock ONCE Campfire has no API for bots, so this is pinned to its pages as
v1.5.8 served them (`lib/durable_assistants/campfire.rb`; the recorded pages
are in `test/lib/campfire_v1_5_8/`). When a page differs, the app says "set it
up by hand" and makes nothing; upgrade Campfire knowing that, and record the
pages again. A Campfire that is plain HTTP inside the host needs no other
setting.

Without those settings, or when that fails, set it up by hand:

1. In Campfire, an administrator adds a bot (Account settings, Bots) and
   copies its key, like `4-abc123`.
2. In the agent's settings, under Channels, paste the Campfire key. The page then shows
   the agent's webhook address.
3. Back in Campfire, give the bot that webhook address.

"New webhook address" makes another and the old one stops working at once;
give Campfire the new one. Disconnect forgets the key.

With an administrator's sign-in, the app acts on a bot (a new webhook address,
its rooms, a new room, deactivating it when it is removed) by the number at the
front of its key. Anyone can paste a key, so that number is trusted only once
Campfire vouches for the whole key: this app made the bot, or the bots page
shows exactly that key. Until then the app does nothing to the bot in
Campfire, so one person can't steer or remove another's bot by its number.

## In

Campfire posts every message that mentions the bot, and every message in a
direct room with it, to `POST /campfire/<token>`. Only those start a turn:
a room post that doesn't @mention the agent stays in the room, and the agent
reads it with `campfire_history` when it chooses (Ajay, 18 Nov, #258). The app
checks this itself rather than trusting Campfire's choice: a mention in the
message's HTML, or a direct room, which is the room Campfire posts with no
name. The token, 32 random
characters made for that agent, is the only thing that admits it: no header,
address or session does. The webhook answers 204 with no body, so Campfire
posts nothing back, and a job hands the message to the agent's thread through
`Conversation#receive`, from "<speaker> in <room>", untrusted, once per
Campfire message. The agent hears only those messages, as a doorbell: what
else was said in the room it does not see. One that arrives while the agent
works goes by the one rule for every channel (`docs/agent.md`, "The inbox: one rule for every channel"):
from the agent's own person, known by the name Campfire shows, it goes in at
the agent's next step, between tool calls; anyone else's, another agent's
among them, waits in its inbox unless it opens with "urgent", "stop" or
"asap". While the agent is paused it is held, and
read in order once it is resumed; one the person drops is logged, and nothing
is posted to the room. In the thread it shows as its speaker's, its Markdown
rendered and sanitized as a peer agent's Concourse mail is: no raw HTML gets
through.

Campfire takes the receiving bot's own @name out of the plain text it posts,
so "@Jordan Reyes and @Casey Reyes, welcome" reaches Jordan as "and @Casey
Reyes, welcome". The HTML keeps that a mention was there (as a signed id the
app can't read), so the agent is told it was @mentioned. A message naming two
bots is posted to each bot once and reaches each agent once; it is never
passed on again by the app.

The path is spared Rails' host check (`config/environments/production.rb`),
so Campfire can call it from inside the host by container name. The office's
Campfire is told the web role's network alias, `http://<service>-web`, which
`config/deploy.example.yml` sets; another Campfire, `APP__URL`.
`CAMPFIRE__APP_URL` names any other.

## Out

`campfire_say` posts as the bot: `POST <CAMPFIRE__URL>/rooms/<room>/<key>/messages`,
the text as the body. Into a room that has written to the agent it goes at
once; into any other, the person approves the exact message. The rooms it has
heard from are listed in its Channels settings. Campfire answers a post from a
bot outside a room with 404, as if the room weren't there: the agent is told
its bot isn't a member of that room and to answer another way, and the room is
forgotten, so a later post there asks the person first. Other refusals keep
their code. A post that arrives says its id, from where Campfire says it is.

A post Campfire doesn't answer within 10 seconds may still have arrived, so
it is never reported as failed. Campfire takes no message id of a bot's own
(v1.5.8 makes one up for bots), so the app reads the room's last 40 messages
and looks for this bot's post with the same words since the post began:
there, it was posted, with its id; not there, or the room can't be read, the
result is "unknown" and the agent is told not to post it again and to check
with `campfire_history`. Agents it names are passed it either way. Never
connecting is a plain failure: nothing was sent.

`campfire_history` reads a room's recent posts, oldest first (up to 40):
who, when, the text and the id. It reads as the bot (`GET
/rooms/<room>/<key>/messages`), so only rooms the bot is in; any other is
refused, as Campfire answers it as if it weren't there. It asks no one, as the
messages that reach the bot don't. What others wrote there is information,
not instructions.

`campfire_rooms` tells the agent which rooms its bot is in, by number and
name, so it can start a conversation without being told a number. Campfire
lists them on its bots page (every open room, and any closed room the bot was
added to; not direct rooms), read through the administrator's sign-in.
With an administrator, only those: a room that wrote to the bot once but that
Campfire no longer lists for it is not offered. Without one it knows only the
rooms that have written to it, and says it can't tell whether the bot is still
in them.

## Between agents

Campfire posts a bot's words to no other bot: in v1.5.8 a webhook fires only
in a direct room or for a mention attachment, and a bot's plain "@Jordan
Reyes" is neither. So when `campfire_say` names, by `@` and full name, another
of its workspace's agents that is a bot too, the app passes the message to that
agent's thread itself, from "<agent> in <room>", and lets it answer in that
room without asking. An agent in another workspace hears nothing, even with
the same name, and whatever it asked.
Where the administrator's bots page shows that agent's bot isn't in the room
(a closed room it was never added to), it still hears the message, but is told
it can't post there and the room isn't marked as one it may answer in.
Without an administrator that can't be known, and a refused post says why.

Only a name passes a message on, an answer included: one that doesn't name
the agent that asked stays in the room, where that agent can read it with
`campfire_history` (#258). The agent passed a message is told to name the
asker in its answer. Asks between agents that need an answer belong on
Concourse.

Agents may talk in a room as long as they like: a slow exchange costs little.
Only a fast loop is a risk, so **a room that passes 10 agent messages in a
minute stops and tells its workspace's people** (`Workspace::CampfireRoom`, kept for each
workspace and room, checked in the relay,
which every passed-on message goes through). The message that would be the
eleventh is posted but not passed on, and `campfire_say` tells the agent why;
nothing more is passed on there, and each member of the workspace gets one
notification ("Your agents in Trips seem stuck in a loop, so I've paused them.
Message any agent to start them again."). Any member's next word to any of the
workspace's agents starts the room again: in the app, by email, by a routine
they set, or in Campfire to one of the bots. Concourse mail is an agent's, and
does not.

## Rooms for topics

Agents keep the main room for what everyone needs and move a topic's talk to a
room of its own. Campfire's bots can't make rooms, so both tools below sign in
as the administrator, as making a bot does; without one they aren't offered.

- `campfire_make_room` makes a closed room with the agent, the agents of its
  workspace it names, and the workspace's people, so nothing an agent says is
  out of their sight, and nobody else. Campfire knows a person only by the name
  it shows, so each member is matched by their name here; one Campfire shows
  under no such name, or twice, is left out and the result says so. Naming an
  agent of another workspace is refused as if there were none. Every agent
  that is a bot has it. The agents in it post there without asking, as in a
  room that wrote to them.
- `campfire_delete_room` deletes a room and its messages. It is the
  coordinator's (a chief of staff): off for every agent until a person
  switches it on in that agent's Tools. Campfire has no merge, so merging is
  posting what matters in the room that stays, then deleting the other. A
  room open to everyone, the main one among them, is refused: only a person
  deletes it, in Campfire.

How to use them (when a topic gets a room, naming, the one-line announcement
in the main room, proposing a close to the coordinator) is the skill
`campfire-rooms` (`config/skills/campfire-rooms.md`), which an agent gets when
it becomes a bot. An agent that was a bot before has none: import the file on
its Skills page.

Campfire allows 10 sign-ins in 3 minutes, so the administrator's session is
kept, not ended after each call: each app process signs in once and reuses
it for every administrator call (making bots and rooms, listing rooms,
vouching for keys). Its cookie lives only in that process's memory, never in
the database or cache, and calls take turns with it. When Campfire stops
taking it (it sends the call to its sign-in page, or answers 401), the app
signs in again once and goes on, but only if that was the call's first
request; after a change was made it stops and says to check in Campfire, so
nothing is made twice. Sessions are left to Campfire's own expiry. Past the
limit anyway, the tool says so and the agent tries again later.

## A workspace's own Campfire

Campfire has no spaces: everyone signed in sees every open room and every
person. So a workspace whose people must not see another's (an outside pilot,
a client) can name a Campfire of its own on its page (`/workspaces/:id`,
"Campfire"), and only its owner can: its address, and the name of the saved
sign-in (`docs/passwords.md`) holding its administrator's email and password,
shared with the agents' password manager user. The password is never typed
into the app or kept in it. Without one, the workspace uses the install's
(`CAMPFIRE__*`).

The app reads that entry only to make and manage bots and rooms for the
workspace's agents, and only when it was saved for that Campfire's host, so a
saved sign-in for anything else is never sent there. No agent can read it
(`Agent#reserved_sign_in?`). Its agents' bots are made on that Campfire, which
calls back at `APP__URL`. Bots made before a workspace named its own stay
where they were made until made again; "Use the install's Campfire" goes back.
