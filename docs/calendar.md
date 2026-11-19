# Calendars and task lists

An agent reads and changes calendars and task lists on the install's CalDAV
server, as its own account, or on a server of its own its owner names
(below). Rails keeps no copy: every read asks the server,
and every change is one write that names the version it read, so nothing a
person changed meanwhile on a phone is overwritten.

Calendar requests, including reads, run outside the invocation ledger's
write transaction. A slow calendar server does not hold up unrelated edits.

## Setting it up

1. The install names its server: `CALDAV__URL=https://caldav.example.com`.
   Unset, no agent has calendar tools and Channels shows no Calendar.
2. Each agent gets its own account on that server, and an app password for
   it. The person enters both on the agent's Channels page, under Calendar.
   The password is stored encrypted with the agent and never shown again; a
   blank password keeps the saved one, and a blank account takes it away.
3. To let an agent see someone's calendar, share that list with the agent's
   account on the server. A shared list shows in the agent's home like its
   own, and the agent can change it only if the share allows.

The account is the boundary. The agent asks only for its own home
(`/<account>/`), and a list or item name is one plain path segment, so it
cannot reach another account's paths.

## A linked calendar from another account

An agent may also reach one calendar in another CalDAV account, such as a
family's shared calendar on iCloud, beside its own lists or without any. The
calendar tools see it as one more list, named by the last part of its
address (`family` for `.../calendars/family/`).

iCloud, like many servers, signs in with an app password that opens the whole
account: every calendar, the contacts, the mail. So:

1. Save the account's username and app password in the password manager
   ([passwords](passwords.md)), with the calendar server's address
   (`https://p01-caldav.example.com`, say), and share it with the agent. The
   password is sent only to the host saved with it.
2. On the agent's Channels page, under Linked calendar, give the server, the
   one calendar, and the saved entry's name. The calendar is its collection's
   full address, or its path or id under the server's address. Give the
   collection itself: nothing is discovered, so the account's principal and
   home are never asked for. For iCloud, copy it from a CalDAV client that
   already shows the calendar. Press Link calendar: the three are saved
   together or not at all, and a refusal says why beside the form and keeps
   what was typed. A `.` or `..` in the calendar or the server's path is
   refused as typed, before it could be resolved to some other address.
3. Press Unlink to stop. It clears all three at once.

With the password manager set up, an agent's settings show Channels for the
linked calendar even where the install has no other channel.

`DurableAssistants::Caldav::Scoped` makes every request to it, and it checks
the address each request is about to go to: the collection itself, or one
`.ics` item directly in it, on the same server, with no query. Anything else
(another calendar in the account, `../`, the principal, contacts) is refused
before the vault is read or anything is sent.

The username and app password are read from the vault, as the agent, for
each request, and are dropped after it. They are never stored, shown to the
agent or the model, written to the ledger or logged; an answer that echoes
the password carries `[the saved password]` instead. The agent never sees
them and cannot change where they go: only a person changes these settings.

If the agent's own account has a list with the linked calendar's name, the
linked calendar takes the name and the own list is not shown. Listing every
calendar asks both servers, so while the linked server is down,
`calendar_lists` and a search across every list fail; one named list still
works.

## Its own calendar server

An agent's own calendars and task lists may live on a CalDAV server of its
own, such as the one beside its own mail account (#77), instead of the
install's. On the agent's Channels, **Calendar server** takes two things:
the address of the account's calendar home (the collection that holds its
calendars, `https://caldav.example.com/calendars/desk/`, never the server's
top) and the name of a saved sign-in holding the account's username and
password, saved with the server's address and shared with the agent.

- **Who sets it.** Only the owner of the agent's workspace sees the section
  or changes it, as for its mail account; to another member it is not
  there, and its address answers 404. It is offered only where the agent
  can reach the password manager.
- **What it does.** Set, and with the password manager reachable, it
  replaces the agent's account on the install's server: `calendar_lists`
  and the other tools see the home's lists, and nothing of the install's
  account. A linked calendar still sits beside it. Remove it and the
  install's account, if any, is used again. It alone gives the agent the
  calendar tools, even where the install names no CalDAV server.
- **How far it reaches.** `DurableAssistants::Caldav::Home`, built on
  `Caldav::Scoped`, checks the address each request is about to go to: the
  home itself, one list directly in it, or one `.ics` item directly in a
  list, on the same server, with no query. Anything else (the principal,
  another account, `../`) is refused before the vault is read or anything
  is sent. Nothing is discovered: the home is the address given.
- **The password.** Read from the vault, as the agent, for each request,
  and sent only if the saved sign-in's address names the server's host;
  never stored, shown to the agent or the model, written to the ledger or
  logged. An answer that echoes it carries `[the saved password]`.
- **The address** must be https, with no sign-in, query, `#`, or `.` or
  `..` in its path, as typed.

## Read-only calendar servers

A colleague's calendars and task lists, taken over with their work, sit
beside the agent's own and are only read. On the agent's Channels, below
**Calendar server**, **Read-only calendar servers** lists each, with
**Add a read-only calendar server** taking the account's calendar home and
a saved sign-in, as for its own server.

- **Who sets it.** Only the workspace's owner; to another member it is not
  there, and its addresses answer 404.
- **Its lists.** Each list is named for its server, `work@dav.example.com`,
  so it never shadows one of the agent's own, and shown as `(read only)`.
  `calendar_lists` and `calendar_find` read them; there are no new tools. A
  read-only server alone gives the agent the calendar tools.
- **Nothing is written there.** `calendar_save_event`, `calendar_save_task`
  and `calendar_delete` refuse a read-only list before anything is read or
  sent, and the client (`DurableAssistants::Caldav::ReadOnly`) refuses a save
  or delete there whatever asks.
- **How far it reaches, and the password,** as for its own server
  (`Caldav::Home`); its saved sign-in is never filled into a browser.
- One read-only server per host, since its lists are named for it.

## The tools

| Tool | Does |
|---|---|
| `calendar_lists` | Names the account's calendars and task lists, its own and those shared with it, each with `own`: whether it is the agent's own list or only shared with it. |
| `calendar_find` | Events between two times (two weeks from now by default), or tasks by whether they're done and when they're due, in one list or all; optionally only those mentioning some words. An event shows whether it is free or busy; a task, its place and whether it fires on arriving or leaving. Each shows its alarms at a time: so many minutes before or after its start, end or (a task) due time, or at a moment, with the alarm's action. |
| `calendar_save_event` | Adds an event, or changes one: only what the agent names changes. Repeats, a reminder, attendees, free or busy. |
| `calendar_save_task` | Adds a task, or changes, completes or reopens one. A reminder at a time, a reminder on arriving at or leaving a saved place, or both. |
| `calendar_delete` | Deletes an event (a repeating one entirely) or a task. |

Times are in the agent's time zone (its Settings) unless the agent gives an
offset, and are written with that zone, so a weekly event keeps its hour
across a change of daylight saving time. A date alone is all day.

The server expands a repeating event into its occurrences within the range
asked for; Rails has no repeat logic of its own. Changing or deleting by id
acts on the whole series.

## Alarms on its own tasks

A reminder that comes due on a task in a task list the agent **owns** starts
a turn for it (#246): the task's title, its notes, when it is due and which
list it is on reach its thread. They arrive untrusted, like mail: whoever
edited the task on a phone wrote them, so they are a task to act on rather
than instructions from the person. Nothing is approved differently and no
tool is loosened; the agent acts with the tools it already has.

- **Whose lists.** Only lists the agent's own account owns, on the install's
  server or on a calendar server of its own. The server says who owns each
  collection (`DAV:owner`), and the list's owner is matched against the one
  it gives the account's home, whatever a principal's address looks like
  there. A list another account shared into the home (a different owner, or
  CalendarServer's `shared-url`), a server the agent only reads and its
  linked calendar are someone else's and wake whoever owns them. A server
  that names no owner says nothing either way, so nothing on it wakes the
  agent: in doubt, a list counts as shared.
- **When.** Every minute `TaskAlarmSweepJob` queues one read for each agent
  with calendars of its own (`TaskAlarmJob`), so a server that is slow or
  down holds up no other agent's alarms. Rails keeps no copy of the tasks:
  each run reads the lists and takes the alarms of the last ten minutes
  (`Agent::TaskAlarm::LOOKBACK`). Each wake carries the alarm's own id,
  `alarm:<agent>:<list>/<task>:<time>`, so overlapping runs, a retry and a
  restart wake the agent once, and an old alarm is never replayed.
- **A busy agent** is not interrupted, as for a routine: the alarm wakes it
  on a later minute, once. An agent busy for the whole ten minutes misses
  that alarm.
- **Which alarms.** A trigger at a time, or so long before the task's due
  time or its start (`RELATED`); a task with only one of the two counts from
  the one it has. A task that is done or cancelled wakes nobody, and a
  reminder for a place fires there, not at a time (above).
- **Repeating tasks.** The server expands no repeating task, so a repeating
  task's alarm wakes the agent for the time stored on it, not for each
  later repeat.

## Reminders on arriving or leaving

`calendar_save_task` takes `location`, a saved place's name, and `proximity`,
`arrive` or `leave` (left out, as it was, or `arrive`). The task gets the alarm iOS Reminders
writes for "When arriving" or "When leaving": its own `VALARM`, beside any
reminder at a time, never in place of one.

```
BEGIN:VALARM
ACTION:DISPLAY
DESCRIPTION:Reminder
TRIGGER;VALUE=DATE-TIME:19760401T005545Z
UID:<new>
X-APPLE-PROXIMITY:ARRIVE
X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-ADDRESS=...;X-APPLE-RADIUS=100;X-APPLE-REFERENCEFRAME=1;X-TITLE=<place>:geo:<lat>,<lon>
X-WR-ALARMUID:<new>
END:VALARM
```

The trigger is Reminders' own fixed time long past, so the alarm fires only
at the place. `leave` writes `DEPART`. A new place replaces the task's old
one; `location: ""` removes it and leaves the reminder at a time alone, and
`alarm_minutes` leaves the place alone.

Places are never looked up. A place is saved by setting a location reminder
on a phone: the agent's task lists are read for every location alarm on
them, and the place is written back exactly as the phone stored it, address,
radius and all, so the phone shows the place it knows. A name nobody saved
is refused, and the refusal names the saved places. The places are the
person's own, kept where their reminders are; nothing is stored in Rails and
there is nothing to set up.

Radicale 3.8.0 parses with vobject 0.9.9, which cuts a `VALUE=URI` property
at its first comma, so the stored place keeps its latitude and loses its
longitude. An install running it mounts a small patch
(`test/radicale/sitecustomize.py`) on Radicale's `PYTHONPATH`. A place
without both is not learned. `test/integration/radicale_location_test.rb`
checks the round trip against a throwaway Radicale when `RADICALE_URL` is set;
it says how to start one.

## What asks first

Adding attendees from outside the install's people asks the person first,
like mail to them, unless they allowed it "Always". Everything else in the
agent's own calendars and its linked calendar runs at once. `APP__APPROVALS=allow` lets it all run.

Adding attendees records them on the event. Whether they hear about it
depends on the server: Radicale, for one, sends no invitations.

## What it writes

Changes keep everything the agent didn't name, including a phone's own
fields, alarms and attendees' replies.

`free: true` writes `TRANSP:TRANSPARENT`, so the time shows as free to anyone
checking availability; `free: false` writes `TRANSP:OPAQUE`, busy. A new event
without `free` is written `TRANSP:OPAQUE` outright rather than left to the
standard's default, so every reader sees what was meant. A change without
`free` leaves the event's `TRANSP` as it was, or absent if it was (which
`calendar_find` shows as busy, as the standard says). A change raises the event's
`SEQUENCE`. A write refused because the item changed since it was read tells
the agent to find it again and retry. A change whose read fails (the server
unreachable, or answering with an error) tells the agent why and that nothing
was changed: the read comes before the one write.

A save the server may have taken anyway (it answered 5xx, or took the
request and timed out or dropped the connection) is read back before the
agent is told anything. A new item landed if anything is at its id, which is
fresh. A change landed if the stored item carries the `SEQUENCE` and
`LAST-MODIFIED` the save stamped on it. Landed, the call succeeds as if the
server had said so, and the agent does not save it twice. Not landed, the
agent is told so and that it is safe to try again: a retry of a change names
the version it read, so even if the save landed after all and a phone has
changed it since, the server refuses the retry rather than writing it twice.
If the read back fails too, the agent is told it may or may not have
happened and to check before trying again. A refusal (4xx) or a connection
never made wrote nothing and is not read back. Each failed call also logs
one warning with the tool, the error's class and the server's status, never
what was read or written, so the install's log says what failed without the
error tracker.

`config/initializers/icalendar.rb` fixes the icalendar gem writing a zero
duration as `P`. Without it, Radicale would refuse every later save of an
item with an alarm at the time.
