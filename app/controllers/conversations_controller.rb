class ConversationsController < ApplicationController
  # The URL holds the list's state, so Back, a reload and a shared link all
  # show the same list.
  def index
    @list = list_params
    @conversations = set_page_and_extract_portion_from(
      Current.user.conversations.threads.includes(agent: :computer).with_preview.filtered_by(params[:filter]).search(params[:q]).sorted_by(params[:sort]).strict_loading,
      per_page: Conversation::PER_PAGE).load
  end

  def show
    @conversation = Current.user.conversations.find(params[:id])
    @agent = @conversation.agent
    sync_quietly
    # Opened, it is read. Turbo fetching it ahead of a click is not opening it,
    # but the click then shows that page without asking again, so the page
    # reads it once shown (reading_controller).
    @fetched_ahead = request.headers["X-Sec-Purpose"] == "prefetch"
    @conversation.read! unless @fetched_ahead
    @page = Conversation::Page.new(@conversation)
    @conversations = Current.user.conversations.threads.active.includes(agent: :computer).with_preview.sorted_by("recent").strict_loading.limit(Conversation::PER_PAGE)
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
