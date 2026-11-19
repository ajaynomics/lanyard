# Moves an agent to another workspace, as its Move page does (Agent::Movable).
# What it reaches and who reaches it change, so its workspace's owner allows
# every move, even where the install approves everything.
class Tool::MoveAgent < Tool
  include Tool::WorkspaceCalls

  description "Move yourself or another agent to another workspace of your person's, when they ask. Its thread, " \
    "notes, computer and channels go with it; the old workspace's connectors and people stay behind."
  argument :to, :string, min_length: 1, max_length: 100, description: "The workspace's name, as list_workspaces gives it."
  argument :agent, :string, required: false, max_length: 200, description: "The agent's name. Left out, you."
  asks :approval, even_approving_everything: true

  def approval_title(arguments) = "Move #{arguments["agent"].presence || agent} to #{arguments["to"]}?"

  def approval_note(_arguments)
    "Its thread, notes, computer and channels go with it. The connectors, contact routes and \"Always\" answers of people who " \
      "are not in the new workspace stay behind. Only #{person} can allow it."
  end

  def call(to:, agent: nil)
    moving, destination = check
    moving.move_to(destination, by: person) or raise Tool::Refusal, moving.errors.full_messages.to_sentence
    { moved: moving.name, to: destination.to_s }
  end

  private
    def check
      name, to = arguments.values_at("agent", "to")
      moving = name.blank? ? agent : agent_named(name)
      destination = workspace_named(to)
      refusal = moving.move_refusal(destination, by: person)
      raise Tool::Refusal, refusal if refusal
      [ moving, destination ]
    end

    def agent_named(name)
      found = nameable.flat_map { it.agents.to_a }.select { it.name.casecmp?(name.squish) }
      raise Tool::Refusal, "No agent you can name is called #{name}." if found.none?
      raise Tool::Refusal, "More than one agent is called #{name}." if found.many?
      found.sole
    end
end
