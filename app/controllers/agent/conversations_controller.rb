module Agent
  class ConversationsController < BaseController
    def index
      @conversations = @access.conversations.order(created_at: :desc)
    end

    def show
      @conversation = conversation
      @snapshot = @conversation.snapshot(@access)
    end

    # Admission is idempotent on (actor, workspace, request_id) on both sides:
    # a retried form post finds the same sidecar conversation and record.
    def create
      identity = request_id
      remote = client.conversation(@access, identity).fetch("id").to_s
      @conversation = admit(identity, remote)
      return if performed?
      respond_to do |format|
        format.html { redirect_to workspace_agent_conversation_path(@access.workspace_id, @conversation), status: :see_other }
        format.json { render json: { id: @conversation.id, durableId: @conversation.durable_id }, status: :created }
      end
    end

    private
      # A sidecar conversation already recorded under another request, or a
      # request recorded with another sidecar conversation, means the sidecar's
      # store and this database are not from the same point in time (a store
      # replaced or restored alone). Refuse rather than guess (docs/agent.md).
      def admit(identity, remote)
        conversation = @access.conversations.create_or_find_by!(request_id: identity) { |record| record.durable_id = remote }
        conversation.durable_id == remote ? conversation : head(:conflict)
      rescue ActiveRecord::RecordNotFound
        head :conflict
      end
  end
end
