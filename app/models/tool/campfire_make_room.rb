# A Campfire room for one topic, so its talk leaves the main room. Made through
# the administrator's sign-in, as bots are: a bot can't make rooms. The
# workspace's people are in it, so nothing an agent says is out of their
# sight; of the agents, only the maker and those of its workspace it names.
# Nobody else is (docs/design/workspaces.md, 2.1). They post there without
# asking, as in a room that wrote to them.
class Tool::CampfireMakeRoom < Tool
  description "Make a Campfire room for one topic and the agents working on it, so its talk leaves your main room. " \
    "Your workspace's people are in it. Say in your main room, in one line, what it is for and its number."
  argument :name, :string, min_length: 1, max_length: 50, description: "Short and plain, what the room is about: \"Lisbon trip\"."
  argument :agents, :array, required: false, max_items: 20, items: { type: "string", maxLength: 200 },
    description: "Other agents to bring in, by full name: \"Jordan Reyes\". You are always in it."
  effect :external

  def permitted? = agent.campfire_bot.present? && agent.campfire.admin?

  def call(name:, agents: [])
    others = agent.workspace.agents.where(name: agents).where.not(id: agent.id).includes(:campfire_bot)
    unknown = agents - others.map(&:name) - [ agent.name ]
    raise Refusal, "No agent here is named #{unknown.to_sentence}." if unknown.any?
    unbotted = others.reject(&:campfire_bot)
    raise Refusal, "#{unbotted.map(&:name).to_sentence} has no Campfire bot." if unbotted.any?
    bots = [ agent.campfire_bot, *others.map(&:campfire_bot) ]
    people = agent.workspace.members.map(&:to_s)
    made = agent.campfire.admin.create_room(name: name, bot_ids: bots.map(&:confirmed_campfire_id), people: people)
    bots.each { it.hear(made[:room], name) }
    left_out = people.reject { |person| made[:people].any? { it.casecmp?(person) } }
    { room: made[:room], name: name, agents: [ agent.name, *others.map(&:name) ], people: made[:people], left_out: left_out.presence }.compact
  rescue DurableAssistants::Campfire::Error => error
    raise Refusal, error.message
  end
end
