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
agent with its webhook address, reads the bot's key from the bots page and
signs out. The bot joins every open room, such as All Talk. "New webhook
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
direct room with it, to `POST /campfire/<token>`. The token, 32 random
characters made for that agent, is the only thing that admits it: no header,
address or session does. The webhook answers 204 with no body, so Campfire
posts nothing back, and a job hands the message to the agent's thread through
`Conversation#receive`, from "<speaker> in <room>", untrusted, once per
Campfire message. The agent hears only those messages, as a doorbell: what
else was said in the room it does not see.

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
heard from are listed in its Channels settings.

`campfire_rooms` tells the agent which rooms its bot is in, by number and
name, so it can start a conversation without being told a number. Campfire
lists them on its bots page (every open room, and any closed room the bot was
added to; not direct rooms), read through the administrator's sign-in.
Without an administrator it knows only the rooms that have written to it, and
says so.

## Between agents

Campfire posts a bot's words to no other bot: in v1.5.8 a webhook fires only
in a direct room or for a mention attachment, and a bot's plain "@Jordan
Reyes" is neither. So when `campfire_say` names, by `@` and full name, another
of the person's agents that is a bot too, the app passes the message to that
agent's thread itself, from "<agent> in <room>", and lets it answer in that
room without asking. Another person's agent of the same name hears nothing.

An answer need not name the asker. The agent the app passed a message to
remembers, per room, who asked (`CampfireBot#askers`), and what it posts
there next goes back to that agent too, named or not, and is told so. An agent
asked for a status update that answers "All on track." would otherwise never
reach the one waiting for it. Once a person writes to the bot in that room,
its posts there answer the person and go to no agent unnamed.

Agents may talk in a room as long as they like: a slow exchange costs little.
Only a fast loop is a risk, so **a room that passes 10 agent messages in a
minute stops and tells its person** (`CampfireRoom`, checked in the relay,
which every passed-on message goes through). The message that would be the
eleventh is posted but not passed on, and `campfire_say` tells the agent why;
nothing more is passed on there, and the person gets one notification
("Your agents in Trips seem stuck in a loop, so I've paused them. Message any
agent to start them again."). The person's next word to any of their agents
starts the room again: in the app, by email, by a routine they set, or in
Campfire to one of the bots. Concourse mail is an agent's, and does not.

## Rooms for topics

Agents keep the main room for what everyone needs and move a topic's talk to a
room of its own. Campfire's bots can't make rooms, so both tools below sign in
as the administrator, as making a bot does; without one they aren't offered.

- `campfire_make_room` makes a closed room with the agent, the agents it names,
  and every person in Campfire, so nothing an agent says is out of a person's
  sight. Every agent that is a bot has it. The agents in it post there without
  asking, as in a room that wrote to them.
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

Campfire allows 10 sign-ins in 3 minutes, and each room made or deleted is one;
past that, the tool says so and the agent tries again later.
