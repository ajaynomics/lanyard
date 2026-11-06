module Agent
  # Only the application's own adapters mint an access. A workspace id in a
  # request is a lookup key, never authority, and without an adapter every
  # request is refused.
  #
  #   config.x.pi_durable_identity  = ->(controller) { the signed-in principal (responds to #id) or nil }
  #   config.x.pi_durable_authorize = ->(actor_id, workspace_id) { an Agent::Access for exactly that pair, or nil }
  class Access
    class Unauthenticated < StandardError; end
    class Forbidden < StandardError; end

    attr_reader :actor_id, :workspace_id, :cwd

    def initialize(actor_id:, workspace_id:, cwd:)
      @actor_id = actor_id.to_s
      @workspace_id = workspace_id.to_s
      @cwd = cwd.to_s
      raise Forbidden unless [ @actor_id, @workspace_id ].all? { |id| self.class.valid_id?(id) }
      raise Forbidden unless Pathname.new(@cwd).absolute?
      freeze
    end

    def self.valid_id?(value)
      value.is_a?(String) && value.match?(/\A[\w.:-]{1,128}\z/)
    end

    def self.for_browser(controller)
      authenticate = DurableAssistants::PiDurable.adapter(:pi_durable_identity)
      principal = authenticate&.call(controller)
      raise Unauthenticated unless principal.respond_to?(:id) && principal.id.present?
      resolve(principal.id.to_s, controller.params[:workspace_id])
    end

    def self.resolve(actor_id, workspace_id)
      raise Forbidden unless valid_id?(actor_id) && valid_id?(workspace_id)
      authorize = DurableAssistants::PiDurable.adapter(:pi_durable_authorize)
      access = authorize&.call(actor_id, workspace_id)
      raise Forbidden unless access.is_a?(self) && access.actor_id == actor_id && access.workspace_id == workspace_id
      access
    end

    def conversations
      Conversation.owned_by(self)
    end

    def notes
      Note.owned_by(self)
    end

    def effects
      Effect.owned_by(self)
    end
  end
end
