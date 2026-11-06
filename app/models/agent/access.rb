module Agent
  # What the sidecar is allowed to act on: one user's one bot. The sidecar
  # names these as actorId (the user) and workspaceId (the bot); an id on the
  # wire is a lookup key, never authority, so every access is minted from a
  # bot reached through its user.
  class Access
    class Forbidden < StandardError; end

    attr_reader :bot, :actor_id, :workspace_id, :cwd

    def self.for(bot)
      new(bot)
    end

    def self.resolve(actor_id, workspace_id)
      raise Forbidden unless [ actor_id, workspace_id ].all? { |id| valid_id?(id) }
      user = User.find_by(id: actor_id) # tenancy-ok: the sidecar names the actor; the bot is then reached through it
      bot = user&.bots&.find_by(id: workspace_id)
      raise Forbidden unless bot
      new(bot)
    end

    def self.valid_id?(value)
      value.is_a?(String) && value.match?(/\A[\w.:-]{1,128}\z/)
    end

    def initialize(bot)
      @bot = bot
      @actor_id = bot.user_id.to_s
      @workspace_id = bot.id.to_s
      @cwd = bot.workdir
      freeze
    end
  end
end
