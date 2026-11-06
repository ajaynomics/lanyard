class ConversationsController < ApplicationController
  before_action :set_bot, only: %i[ index create ]

  def index
    @conversations = @bot.conversations.order(updated_at: :desc)
  end

  def show
    @conversation = Current.user.conversations.find(params[:id])
    @bot = @conversation.bot
  end

  # Admission is idempotent on the form's request id, on both sides: a
  # retried post finds the same sidecar conversation and the same record.
  def create
    conversation = @bot.start_conversation(request_id: request_id)
    redirect_to conversation, status: :see_other
  rescue Conversation::Mismatch
    head :conflict
  end

  private
    def set_bot
      @bot = Current.user.bots.find(params[:bot_id])
    end

    def request_id
      params.expect(:request_id).tap { raise ActionController::BadRequest unless Agent::Access.valid_id?(it) }
    end
end
