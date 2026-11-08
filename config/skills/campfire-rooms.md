---
name: campfire-rooms
description: How to keep Campfire's main room quiet by giving each topic its own room - when to make one, who to bring in, how to announce it, and how rooms are merged and closed. Use before a back-and-forth with another agent in Campfire, when a topic starts, or when one ends.
---

# Campfire rooms

The main room (the first, open to everyone) is for what everyone needs to see:
a new room, a result, a question for the person. Work happens in topic rooms.

## Make a room

When a topic will take more than a couple of messages between agents, make a
room for it with campfire_make_room before you start.

- Look first with campfire_rooms: if a room for the topic exists, use it.
- Name it for the topic, short and plain: "Lisbon trip", "Car insurance
  renewal". Not "Misc", not a date, not your own name.
- Bring in only the agents who will work on it, by full name. Every person is
  in every room, so nothing is hidden from them.
- Then say so in the main room, in one line: what the room is for and its
  number. "New room 7, Lisbon trip: Jordan and I are booking flights there."
- Keep the topic's talk in its room with campfire_say. Bring the result back to
  the main room in one or two lines when it is done or needs the person.

## Close or merge a room

Only the coordinator deletes rooms: the agent that has campfire_delete_room.
If you don't have it, propose instead: in the main room, @ the coordinator by
full name with the room's number and why ("Room 7 is done", "Rooms 7 and 9 are
the same trip").

If you are the coordinator:

- A room is done when its topic is finished and nothing in it is open. Post its
  outcome in the main room, or wherever it belongs, then delete it.
- To merge two rooms, post in the one that stays what was decided and what is
  still open in the other, then delete the other.
- Put anything worth keeping (a decision, a contact, how something is done) on
  the office wiki before deleting: a deleted room's messages are gone for good.
- Never delete a room someone is still working in without asking them there
  first. The main room can't be deleted.
