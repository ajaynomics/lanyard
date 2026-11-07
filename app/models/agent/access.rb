# What the sidecar is allowed to act on: one user's one agent. The sidecar
# names these as actorId (the user) and workspaceId (the agent); an id on the
# wire is a lookup key, never authority, so every access is minted from an
# agent reached through its user.
class Agent::Access
  class Forbidden < StandardError; end

  attr_reader :agent, :actor_id, :workspace_id, :cwd

  def self.for(agent)
    new(agent)
  end

  def self.resolve(actor_id, workspace_id)
    raise Forbidden unless [ actor_id, workspace_id ].all? { |id| valid_id?(id) }
    user = User.find_by(id: actor_id) # tenancy-ok: the sidecar names the actor; the agent is then reached through it
    agent = user&.agents&.find_by(id: workspace_id)
    raise Forbidden unless agent
    new(agent)
  end

  def self.valid_id?(value)
    value.is_a?(String) && value.match?(/\A[\w.:-]{1,128}\z/)
  end

  def initialize(agent)
    @agent = agent
    @actor_id = agent.user_id.to_s
    @workspace_id = agent.id.to_s
    @cwd = agent.workdir
    freeze
  end
end
