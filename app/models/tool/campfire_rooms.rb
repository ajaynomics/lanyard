# The rooms an agent's bot is in, by number and name, so it can start a
# conversation (campfire_say) without being told a room's number. Campfire
# lists them on its bots page, read through the administrator's sign-in;
# without one, only the rooms that have written to the bot are known.
class Tool::CampfireRooms < Tool
  description "List the Campfire rooms your bot is in, by number and name, to post in one with campfire_say. " \
    "A room that has not written to you needs the person's approval to post in."
  effect :external

  def permitted? = agent.campfire_bot.present? && agent.campfire.configured?

  def call
    bot = agent.campfire_bot
    rooms = agent.campfire.admin? ? agent.campfire.admin.rooms_of(bot.confirmed_campfire_id) : {}
    heard = bot.rooms.transform_keys(&:to_i)
    # Where Campfire can say which rooms the bot is in, a room that wrote to
    # it but that it has since left (or was only named in) is not offered.
    known = agent.campfire.admin? ? rooms : heard.merge(rooms)
    listed = known.map { |room, name| { room: room, name: name, wrote_to_you: heard.key?(room) } }
    { rooms: listed.sort_by { it[:room] } }.tap do |result|
      result[:note] = "Only the rooms that have written to you: this install can't ask Campfire for the rest, " \
        "and whether your bot is still in them is not known." unless agent.campfire.admin?
    end
  rescue DurableAssistants::Campfire::Error => error
    raise Refusal, error.message
  end
end
