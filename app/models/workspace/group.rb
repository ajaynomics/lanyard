class Workspace::Group
  attr_reader :workspace, :waiting

  def self.of(person, list = {}, only: nil, message_search: nil)
    waiting = person.needs_you_by_workspace
    workspaces = person.workspaces.personal_first.includes(:memberships)
    workspaces = workspaces.where(id: only.id) if only
    workspaces.map { new(it, list, waiting: waiting.fetch(it.id, []), message_search: message_search) }
  end

  def initialize(workspace, list, waiting:, message_search: nil)
    @workspace, @list, @cards, @message_search = workspace, list, waiting, message_search
    @waiting = @cards.size
  end

  def tree = @tree ||= Workspace::Group::Tree.new(threads, matches, @cards)
  def conversations = tree.roots
  def shown? = !narrowed? || conversations.any?
  def live? = !narrowed?
  def sorted? = live? && @list[:sort].in?([ nil, "", "recent" ])

  private
    def narrowed? = @list[:q].present? || @list[:agent_id].present? || @list[:filter].in?(%w[ waiting archived all ])

    def threads
      workspace.conversations.threads.includes(agent: :computer).with_preview.sorted_by(@list[:sort]).strict_loading.to_a
    end

    def matches
      if narrowed?
        listed = workspace.conversations.threads.filtered_by(@list[:filter])
        listed = @list[:agent_id] ? listed.where(agent_id: @list[:agent_id]) : listed.search(@list[:q])
        listed = listed.where(id: found_threads) if @message_search
        listed.ids.to_set
      end
    end

    # A match in a branch shows on its agent's thread.
    def found_threads
      workspace.conversations.where(id: @message_search.conversation_ids).select("COALESCE(conversations.root_id, conversations.id)")
    end
end
