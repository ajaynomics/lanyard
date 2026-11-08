class ConversationsController < ApplicationController
  # The URL holds the list's state, so Back, a reload and a shared link all
  # show the same list.
  def index
    @list = list_params
    @conversations = set_page_and_extract_portion_from(
      Current.user.conversations.threads.includes(:agent).with_preview.filtered_by(params[:filter]).search(params[:q]).sorted_by(params[:sort]).strict_loading,
      per_page: Conversation::PER_PAGE).load
  end

  def show
    @conversation = Current.user.conversations.find(params[:id])
    @agent = @conversation.agent
    sync_quietly
    @page = Conversation::Page.new(@conversation)
    @conversations = Current.user.conversations.threads.active.includes(:agent).with_preview.sorted_by("recent").strict_loading.limit(Conversation::PER_PAGE)
    # "Edit" opens a branch with the person's words from the parent in the box.
    @draft = @conversation.parent&.messages&.find_by(id: params[:draft], role: "user")&.content if params[:draft]
  end

  # A new name, from `/name` or the pencil beside it: the agent's on its
  # thread, the branch's own on a branch, since a branch's header shows its
  # title. The header and the sidebar follow by broadcast, on every page
  # showing it.
  def update
    conversation = Current.user.conversations.find(params[:id])
    name = params.expect(conversation: [ :title ])[:title].to_s.squish
    if name.present? && rename(conversation, name)
      redirect_to conversation
    else
      redirect_to conversation, alert: "#{conversation.parent_id ? "A branch's" : "An agent's"} name must be 1 to 200 characters."
    end
  end

  private
    def rename(conversation, name)
      if conversation.parent_id
        conversation.update(title: name).tap { conversation.broadcast_title if it }
      else
        conversation.agent.update(name: name)
      end
    end

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
