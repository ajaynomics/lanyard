class ConversationsController < ApplicationController
  before_action :set_bot, only: %i[ index create ]

  def index
    @conversations = @bot.conversations.order(updated_at: :desc)
  end

  def show
    @conversation = Current.user.conversations.find(params[:id])
    @bot = @conversation.bot
    sync_quietly
    @messages = @conversation.messages.shown.includes(:conversation).with_attached_images.to_a
    @invocations = @conversation.invocations.includes(:approval, :answer).index_by(&:call_id)
    @results = @messages.select { it.role == "toolResult" }.index_by(&:tool_call_id)
    @placed = @messages.flat_map { it.tool_calls.pluck("id") }.to_set
    @conversations = @bot.conversations.order(updated_at: :desc).limit(30)
    # "Edit" opens a branch with the person's words from the parent in the box.
    @draft = @conversation.parent&.messages&.find_by(id: params[:draft], role: "user")&.content if params[:draft]
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
    # The page heals whatever pings were lost; an unreachable sidecar still
    # shows the copy Rails has.
    def sync_quietly
      @conversation.sync!
      @conversation.refresh_status!
    rescue DurableAssistants::PiDurable::Client::Error
      flash.now[:alert] = "The assistant is not reachable right now; showing what was saved."
    end

    def set_bot
      @bot = Current.user.bots.find(params[:bot_id])
    end

    def request_id
      params.expect(:request_id).tap { raise ActionController::BadRequest unless Agent::Access.valid_id?(it) }
    end
end
