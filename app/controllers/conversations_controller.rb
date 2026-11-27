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
        # A live tree reloads just its workspace, with this person's controls.
        only = Current.user.workspaces.find(params[:workspace_id]) if params[:workspace_id]
        # Words with an agent chosen search its messages, a batch at a time; words alone, agents' names.
        if @list[:agent_id]
          searched = Current.user.agents.find(@list[:agent_id])
          @message_search = Agent::MessageSearch.new(searched, @list[:q], before: params[:before]) if @list[:q]
        end
        @search_agents = Current.user.agents.order(:name, :id).pluck(:name, :id)
        @groups = Workspace::Group.of(Current.user, @list, only: only, message_search: @message_search)
        if only && turbo_frame_request?
          render partial: "conversations/tree", locals: { group: @groups.sole, list: @list, current: nil }
        end
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
    # The sidecar is asked once the page listens (WorkspaceStreamsChannel), so nothing it says is missed.
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

    def list_params
      params.slice(:q, :sort, :filter, :agent_id).permit(:q, :sort, :filter, :agent_id).to_h.symbolize_keys.compact_blank.merge(lens: agents_lens)
    end

    def agents_lens
      return "list" if hotwire_native_app?

      key = "agents_lens_#{Current.user.id}"
      requested = params[:lens].presence_in(%w[ list chart ])
      if requested && !turbo_frame_request? && request.headers["X-Sec-Purpose"] != "prefetch" && !params[:workspace_id]
        cookies.permanent[key] = { value: requested, httponly: true, same_site: :lax }
      end
      requested || cookies[key].presence_in(%w[ list chart ]) || "list"
    end
end
