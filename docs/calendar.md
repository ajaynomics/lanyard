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
family's shared calendar on iCloud, or several from the same account, beside
its own lists or without any. The calendar tools see each as one more list,
named by the last part of its address (`family` for `.../calendars/family/`),
so two linked calendars must end in different names.

iCloud, like many servers, signs in with an app password that opens the whole
account: every calendar, the contacts, the mail. So:

1. Save the account's username and app password in the password manager
   ([passwords](passwords.md)), with the calendar server's address
   (`https://p01-caldav.example.com`, say), and share it with the agent. The
   password is sent only to the host saved with it.
2. On the agent's Channels page, under Linked calendar, give the server, the
   calendar, and the saved entry's name. The calendar is its collection's
   full address, or its path or id under the server's address; for several
   from the same account, give one a line (up to 20), all on that server and
   signed in with that entry. An agent linked to one calendar before keeps it
   as it was: one line is the old setting. Give each collection itself:
   nothing is discovered, so the account's principal and home are never
   asked for. For iCloud, copy it from a CalDAV client that already shows
   the calendar. Press Link calendar: the three are saved together or not at
   all, and a refusal says why beside the form and keeps what was typed. A
   `.` or `..` in a calendar or the server's path is refused as typed, before
   it could be resolved to some other address.
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

If the agent's own account has a list with a linked calendar's name, the
linked calendar takes the name and the own list is not shown. Listing every
calendar asks each server and each linked calendar. While one cannot be
reached, `calendar_lists` and a search across every list still answer with
the others, and their `unreachable` says what the missing one's server said;
only when none answers do they fail. One named list works as before.

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

## Event-only collections

On **Channels → Calendar server**, the workspace owner can list one to 20
full HTTPS collection addresses instead of the calendar home. Give one per
line, all on the same hostname, with distinct final path names and a trailing
`/`. Choose an existing saved sign-in for that host. The agent queries only
those collections and their direct `.ics` items. It does not look for other
calendars or fall back to the install’s calendar if the vault is unavailable.

Guest events are readable. The agent can add, change or delete ordinary events
without guests or reminders. It cannot add an invitation, change or delete a
guest event, use an alarm or task, or alter the collections. This mode doesn't
change other calendars already connected explicitly.
Apple events with `X-APPLE-*` fields, and events with unsupported `ATTACH`,
`URL` or `ORGANIZER` fields, can be read but cannot be changed or deleted.
The agent leaves those fields and events alone rather than risk losing data
or sending a scheduling message.

An edit or deletion requires the server’s strong version of the event. If
the server returns only a weak version, or another writer changes the event
first, the write is refused. Creating a new event never replaces an existing
item.

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
asked for; Rails expands only what it does not (alarms, below). Changing or deleting by id
acts on the whole series. Radicale before 3.9.0 matches a non-repeating event
with a time zone by its local time read as UTC, so `calendar_find` asks for 14
hours more on each side and keeps what overlaps the range itself
(`test/integration/radicale_calendar_find_test.rb`).

## Alarms on its own lists

A reminder that comes due on an event or a task in a list the agent **owns**
is mailed to the agent's own address: the item's title as the subject, and
when it starts or is due, its notes and its id and list in the body. It comes
from the install's do-not-reply address (`MAIL__ALARMS_FROM`, else
`no-reply@MAIL__DOMAIN`), through the install's SMTP server, never from the
agent's own address, whose mail is dropped as its own. It lands like any other
mail, untrusted: whoever edited the item on a phone wrote it, so it is a
reminder to act on rather than instructions from the person. Nothing is
approved differently and no tool is loosened. An agent with no address to
mail gets no alarms.

- **Whose lists.** Only lists the agent's own account owns, on the install's
  server or on a calendar server of its own. The server says who owns each
  collection (`DAV:owner`), and the list's owner is matched against the one
  it gives the account's home, whatever a principal's address looks like
  there. A list another account shared into the home (a different owner, or
  CalendarServer's `shared-url`), a server the agent only reads and its
  linked calendar are someone else's and reach whoever owns them. A server
  that names no owner says nothing either way, so nothing on it reaches the
  agent: in doubt, a list counts as shared.
- **Whose items.** On an eligible list, an item with no `ATTENDEE` reaches
  every otherwise eligible agent that sees it. If it names attendees, an
  agent gets it only if one of them, or its organizer, is a `mailto:` for its
  full address in this app (case-insensitive). An outside or shared mailbox
  address does not name an agent. An attendee does not grant calendar access
  or make a shared list eligible.
- **When.** Every minute `AlarmSweepJob` queues one read for each agent with
  calendars of its own (`AlarmMailerJob`), so a server that is slow or down
  holds up no other agent's alarms. Each agent keeps how far it has read
  (`alarms_read_until`); a read mails every alarm since then, whether the
  agent is busy or not, and moves it past each moment only once every
  alarm that fired then went, so a failed send is retried alone. Its
  first read starts then. After downtime it reads back at most a day, and
  what came due more than ten minutes ago arrives in one message.
- **Once.** A read of an agent at a time. A message's Message-ID is the
  alarm's own, keyed on the `VALARM` (its UID, else its place on the item)
  and the occurrence it fires for (its `RECURRENCE-ID`, else its start): each
  repeat is mailed once, and one mailed again reaches the thread once.
- **Which alarms.** A trigger at a time, or so long before an item's start or
  its end, an event's end or a task's due time (`RELATED`); a task with only
  one of the two counts from the one it has. Days and weeks are calendar
  days, so a reminder a day before 9:00 is at 9:00 the day before across a
  change of clocks. A date alone is the start of that day in the agent's time
  zone. A task that is done or cancelled, or a cancelled event, reaches
  nobody, and a reminder for a place fires there, not at a time (above).
- **Repeats.** The server expands a repeating event into its occurrences. A
  repeat it leaves alone, as it does a task's, is expanded here (IceCube),
  without its `EXDATE`s; an occurrence moved to an item of its own
  (`RECURRENCE-ID`) fires at its new time only. An item may start at most
  eight days after its alarm.

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

**Any call that will email guests asks the person first**, like mail to them,
unless every one of them is one of the install's own people or the person
allowed those guests "Always". That is one rule for three calls:

* adding an event with guests from outside;
* **changing** such an event, even when it names nobody new — the guests
  already on it get the updated invitation, with whatever the agent has
  written since;
* **deleting** it, which emails them a cancellation.

The card names everyone the mail will reach and says what they will get.
To know who that is, the event is read before anyone is asked; if it cannot
be read, the call asks anyway.

An event with no guests, a task, and an event someone else organises mail
nobody, so they ask nothing and run at once, as everything else in the
agent's own calendars and its linked calendar does. `APP__APPROVALS=allow`
lets it all run.

## Invitations

Neither calendar server this app talks to schedules: Radicale and the shared
host's both answer 404 for a schedule inbox and outbox, and neither mails a
guest. So an event with guests is invited by mail, the way every other mail
program does it (RFC 6047, iMIP), from the address `send_email` would use: the
agent's own mail account where it can send through it (`docs/email.md`, "Its
own mail account"), else its address here, which mail reaches it at too.

An event the agent invites anyone to is written with `ORGANIZER` set to that
address, and each guest gets a message carrying the event:

* a plain-text part saying what it is, when and where;
* a `text/calendar` part whose `Content-Type` says `method=REQUEST`, as the
  standard requires, holding `METHOD:REQUEST` and the event;
* the same thing again as an `invite.ics` attachment, which is what Google's
  and Outlook's mail want before they show the Yes / No buttons.

A change to that event invites everyone on it again, `SEQUENCE` one higher,
so their calendars update rather than gain a second event. Deleting it sends
a `METHOD:CANCEL`, which takes it off their calendars. Reminders are left out:
a guest's own calendar sets its own.

Only an event the agent organises is one it invites to or cancels. An event
someone else organises — a meeting a phone put in the calendar — keeps its own
`ORGANIZER`, and nothing is mailed about it: the standard says the organiser
invites, and this way no guest is mailed whom a person never allowed.

No guest is ever mailed unasked. The approval that first invited someone
covers that invitation's words, not whatever is written or cancelled later,
so each change and each delete asks again ("What asks first" above).

The invitation is recorded before the server is asked and is never sent twice
(`Dispatch`, as `send_email` is: `docs/email.md`, "When the mail server
doesn't answer"). The same event saved again with nothing changed sends
nothing, and the call says so. Nothing about the invitation can fail the
save: the event is already written by then, so the call's answer carries
`invited`, saying it went, that it is still unknown, or why it did not.
An invitation goes at once, including outside the agent's sending hours,
which hold ordinary mail: the event is written then too.

**An agent with no mail address cannot invite anyone**: no account of its
own it can send through, and no address here (its workspace has no agent
mail, or its own account is its only address). There is no address its
guests' answers could come back to, so the event is saved with its attendees
written on it, no `ORGANIZER` is set, nothing is emailed, and the call and the
approval card both say so plainly. Whether those guests ever hear depends on
their own calendar server.

### Answers

A guest's `METHOD:REPLY`, arriving in the agent's mailbox, writes that guest's
`PARTSTAT` on the stored event, so `calendar_find` shows who accepted. It is
applied only when all of this holds:

* the `UID` names an event in one of the agent's own writable lists;
* that event is one the agent organises;
* the message has one `From` address and it matches the `ATTENDEE` in the body;
* a configured receiving server's `Authentication-Results` reports a DMARC
  pass for that exact `From` domain, or a DKIM pass signed by that domain or
  one of its subdomains. A parent or sibling signing domain does not count.

See [`MAIL__AUTHSERV_ID`](email.md#settings) for the receiving server setup.
Without it, or when the sender cannot be verified, no reply changes the event.
The reply still reaches the agent as mail with a note that it was not applied.
The body's `METHOD` decides whether it is a reply, not the `Content-Type`
parameter, because the two disagree in the wild.

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
