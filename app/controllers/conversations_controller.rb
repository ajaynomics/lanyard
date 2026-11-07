class ConversationsController < ApplicationController
  before_action :set_agent, only: %i[ index create ]

  # The URL holds the list's state, so Back, a reload and a shared link all
  # show the same list.
  def index
    @list = list_params
    @conversations = set_page_and_extract_portion_from(
      @agent.conversations.filtered_by(params[:filter]).search(params[:q]).sorted_by(params[:sort]).strict_loading,
      per_page: Conversation::PER_PAGE).load
  end

  def show
    @conversation = Current.user.conversations.find(params[:id])
    @agent = @conversation.agent
    sync_quietly
    @messages = @conversation.messages.shown.includes(:conversation).with_attached_images.to_a
    @invocations = @conversation.invocations.includes(:approval, :answer).index_by(&:call_id)
    @results = @messages.select { it.role == "toolResult" }.index_by(&:tool_call_id)
    @placed = @messages.flat_map { it.tool_calls.pluck("id") }.to_set
    @conversations = @agent.conversations.active.sorted_by("recent").strict_loading.limit(Conversation::PER_PAGE)
    # "Edit" opens a branch with the person's words from the parent in the box.
    @draft = @conversation.parent&.messages&.find_by(id: params[:draft], role: "user")&.content if params[:draft]
  end

  # Admission is idempotent on the form's request id, on both sides: a
  # retried post finds the same sidecar conversation and the same record.
  def create
    conversation = @agent.start_conversation(request_id: request_id)
    redirect_to conversation, status: :see_other
  rescue Conversation::Mismatch
    head :conflict
  end

  # A new title, from `/name` or the pencil beside it. The header and the
  # sidebar follow by broadcast, on every page showing the conversation.
  def update
    conversation = Current.user.conversations.find(params[:id])
    title = params.expect(conversation: [ :title ])[:title].to_s.squish
    if title.present? && conversation.update(title: title)
      redirect_to conversation
    else
      redirect_to conversation, alert: "An agent's name must be 1 to 200 characters."
    end
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

    def set_agent
      @agent = Current.user.agents.find(params[:agent_id])
    end

    def list_params
      params.slice(:q, :sort, :filter).permit(:q, :sort, :filter).to_h.symbolize_keys.compact_blank
    end

    def request_id
      params.expect(:request_id).tap { raise ActionController::BadRequest unless Agent::Access.valid_id?(it) }
    end
end
