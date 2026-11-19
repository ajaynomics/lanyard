# The agent's answer in Campfire, posted as its bot. Into a room that wrote to
# it, it goes at once; into any other, the person approves the exact message.
# A post Campfire doesn't answer in time is looked for in the room: there, it
# was posted; not there, it is unknown, never failed (CampfireBot#say).
class Tool::CampfireSay < Tool
  description "Post a message in a Campfire room as your bot: to answer a Campfire message, in its room. " \
    "A room that has not written to you needs the person's approval. Write @ and another agent's full name " \
    "(@Jordan Reyes) to reach it: the app passes your message on to it."
  argument :room, :integer, minimum: 1, description: "The room's number, as the message you answer gave it or campfire_rooms lists it."
  argument :text, :string, min_length: 1, max_length: 10_000
  asks :approval
  reaches_others
  effect :external
  # Campfire never answered and the room doesn't show the post. Not a
  # failure, which an agent would post again.
  UNCONFIRMED = "Unknown: Campfire didn't answer in time and the room doesn't show your post yet, so it may have been posted. " \
    "Don't post it again; check the room with campfire_history in a minute."

  def asks = (super unless agent.campfire_bot&.heard_in?(arguments["room"]))

  def permitted? = agent.campfire_bot.present? && agent.campfire.configured?

  def recipients = [ "Campfire room #{arguments["room"].to_i}" ]

  def call(room:, text:)
    said = begin
      { posted: true, room: room, id: agent.campfire_bot.say(room, text) }.compact
    rescue CampfireBot::Unconfirmed
      { unknown: true, room: room, note: UNCONFIRMED }
    end
    # Passed on either way: an unknown post most likely arrived, and won't be posted again.
    { **said, **agent.campfire_bot.relay(room, text, key: "relay-#{invocation.id}") }
  end
end
