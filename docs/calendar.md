# Calendars and task lists

An agent reads and changes calendars and task lists on the install's CalDAV
server, as its own account. Rails keeps no copy: every read asks the server,
and every change is one write that names the version it read, so nothing a
person changed meanwhile on a phone is overwritten.

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

## The tools

| Tool | Does |
|---|---|
| `calendar_lists` | Names the account's calendars and task lists, its own and those shared with it. |
| `calendar_find` | Events between two times (two weeks from now by default), or tasks by whether they're done and when they're due, in one list or all; optionally only those mentioning some words. |
| `calendar_save_event` | Adds an event, or changes one: only what the agent names changes. Repeats, a reminder, attendees. |
| `calendar_save_task` | Adds a task, or changes, completes or reopens one. |
| `calendar_delete` | Deletes an event (a repeating one entirely) or a task. |

Times are in the agent's time zone (its Settings) unless the agent gives an
offset, and are written with that zone, so a weekly event keeps its hour
across a change of daylight saving time. A date alone is all day.

The server expands a repeating event into its occurrences within the range
asked for; Rails has no repeat logic of its own. Changing or deleting by id
acts on the whole series.

## What asks first

Adding attendees from outside the install's people asks the person first,
like mail to them, unless they allowed it "Always". Everything else in the
agent's own calendars runs at once. `APP__APPROVALS=allow` lets it all run.

Adding attendees records them on the event. Whether they hear about it
depends on the server: Radicale, for one, sends no invitations.

## What it writes

Changes keep everything the agent didn't name, including a phone's own
fields, alarms and attendees' replies. A change raises the event's
`SEQUENCE`. A write refused because the item changed since it was read tells
the agent to find it again and retry.

`config/initializers/icalendar.rb` fixes the icalendar gem writing a zero
duration as `P`. Without it, Radicale would refuse every later save of an
item with an alarm at the time.
