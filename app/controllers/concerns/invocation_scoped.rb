# A waiting tool call, reached through the signed-in person's conversation. A
# call that is no longer waiting cannot be decided again.
module InvocationScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_invocation
    rescue_from Invocation::Conflict do
      redirect_to @conversation, alert: "That request has already been answered or has expired.", status: :see_other
    end
  end

  private
    def set_invocation
      @conversation = Current.user.conversations.find(params[:conversation_id])
      @invocation = @conversation.invocations.find(params[:invocation_id])
    end
end
