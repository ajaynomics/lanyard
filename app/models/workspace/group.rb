# A workspace in the agents list (conversations#index, a thread's sidebar):
# its threads as the list's search, sort and filter choose, thirty a page, and
# how many cards wait on the person there. The list is every workspace the
# person is in, their own first, as Workspaces › Overview orders them, so
# nobody chooses one to see its agents (#174). Each group is read through its
# workspace, and the workspaces through the person: one they are not in is
# never read.
class Workspace::Group
  attr_reader :workspace, :page, :waiting

  # `only` is one of the person's workspaces, for a later page of its group.
  def self.of(person, list = {}, page: nil, only: nil)
    waiting = person.needs_you_by_workspace
    workspaces = person.workspaces.personal_first.includes(:memberships)
    workspaces = workspaces.where(id: only.id) if only
    workspaces.map { new(it, list, page: page, waiting: waiting.fetch(it.id, []).size) }
  end

  def initialize(workspace, list, page:, waiting:)
    @workspace, @list, @waiting = workspace, list, waiting
    @page = GearedPagination::Recordset.new(threads, per_page: Conversation::PER_PAGE).page(page)
  end

  def conversations = @conversations ||= page.records.load

  # A search or a filter shows only the groups with something in them; the
  # list as it stands shows every one, an empty workspace saying so.
  def shown? = !narrowed? || conversations.any?

  # Only the list as it stands takes a new row: in a search or a filter it
  # might not belong. Sorted by news, a changed row moves to its place.
  def live? = !narrowed?

  def sorted? = live? && @list[:sort].in?([ nil, "", "recent" ])

  private
    def narrowed? = @list[:q].present? || !@list[:filter].in?([ nil, "", "active" ])

    def threads
      workspace.conversations.threads.includes(agent: :computer).with_preview
        .filtered_by(@list[:filter]).search(@list[:q]).sorted_by(@list[:sort]).strict_loading
    end
end
