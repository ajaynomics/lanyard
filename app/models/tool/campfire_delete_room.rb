# Clearing up the rooms agents made: the coordinator's alone, so off unless
# switched on for the agent. Campfire can't merge rooms; merging is posting
# what matters in the room that stays, then deleting this one. A room open to
# everyone, the main one among them, is refused: only a person deletes it.
class Tool::CampfireDeleteRoom < Tool
  description "Delete a Campfire room and every message in it, when its topic is done or merged into another. " \
    "First post in the room that stays what was decided and what is still open. The main room can't be deleted."
  argument :room, :integer, minimum: 1, description: "The room's number, as campfire_rooms lists it."
  effect :external

  def permitted? = CampfireBot.configured? && agent.campfire_bot.present? && DurableAssistants::Campfire.admin?

  def call(room:)
    DurableAssistants::Campfire.admin.delete_room(room)
    agent.user.agents.includes(:campfire_bot).filter_map(&:campfire_bot).each { it.forget(room) }
    { deleted: true, room: room }
  rescue DurableAssistants::Campfire::Error => error
    raise Refusal, error.message
  end
end
