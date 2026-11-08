# The agent's answer in Campfire, posted as its bot. Into a room that wrote to
# it, it goes at once; into any other, the person approves the exact message.
class Tool::CampfireSay < Tool
  description "Post a message in a Campfire room as your bot: to answer a Campfire message, in its room. " \
    "A room that has not written to you needs the person's approval. Write @ and another agent's full name " \
    "(@Jordan Reyes) to reach it: the app passes your message on to it."
  argument :room, :integer, minimum: 1, description: "The room's number, as the message you answer gave it or campfire_rooms lists it."
  argument :text, :string, min_length: 1, max_length: 10_000
  asks :approval
  effect :external

  def asks = (super unless agent.campfire_bot&.heard_in?(invocation.arguments["room"]))

  def permitted? = CampfireBot.configured? && agent.campfire_bot.present?

  def recipients = [ "Campfire room #{invocation.arguments["room"].to_i}" ]

  def call(room:, text:)
    agent.campfire_bot.say(room, text)
    { posted: true, room: room, **agent.campfire_bot.relay(room, text, key: "relay-#{invocation.id}") }
  end
end
