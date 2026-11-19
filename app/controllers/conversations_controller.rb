class ConversationsController < ApplicationController
  allow_watch_access only: :index

  # Every workspace the person is in, each its agents (Workspace::Group). The
  # URL holds the list's state, so Back, a reload and a shared link all show
  # the same list.
  # As JSON, for the Watch: the person's agents to write to, and the calls
  # waiting for their approval.
  def index
    respond_to do |format|
      format.html do
        @list = list_params
        # A later page is one workspace's group alone, loaded as its list scrolls to its end.
        only = Current.user.workspaces.find(params[:workspace_id]) if params[:workspace_id]
        @groups = Workspace::Group.of(Current.user, @list, page: params[:page], only: only)
      end
      format.json do
        agents = reach.conversations.threads.active.includes(:agent).sorted_by("recent").limit(Conversation::PER_PAGE)
        render json: { agents: agents.map { { conversation_id: it.id, name: it.agent.to_s } },
          approvals: reach.invocations.waiting_for_approval.map { Invocation::Card.new(it) } }
      end
    end
  end

  def show
    @conversation = find_in_workspace(:conversations, params[:id])
    @agent = @conversation.agent
    sync_quietly
    # Opened, it is read. Turbo fetching it ahead of a click is not opening it,
    # but the click then shows that page without asking again, so the page
    # reads it once shown (reading_controller).
    @fetched_ahead = request.headers["X-Sec-Purpose"] == "prefetch"
    @conversation.read! unless @fetched_ahead
    @page = Conversation::Page.new(@conversation)
    @groups = Workspace::Group.of(Current.user)
    # Something shared from another app (SharesController): its words in the box, its pictures attached.
    @share = Current.user.shares.find_by(id: params[:share]) if params[:share]
    @draft = @share&.text.presence
  end

  private

    # The page heals whatever pings were lost; an unreachable sidecar still
    # shows the copy Rails has.
    def sync_quietly
      @conversation.admit!
      @conversation.sync!
      @conversation.refresh_status!
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch
      flash.now[:alert] = "The agent is not reachable right now; showing what was saved."
    end

    def list_params
      params.slice(:q, :sort, :filter).permit(:q, :sort, :filter).to_h.symbolize_keys.compact_blank
    end
end
