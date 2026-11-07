# A conversation's family, nested: the conversation every branch came from at
# the top, each branch under the one it was taken from. Three queries in all,
# however many branches there are.
class Conversation::Tree
  attr_reader :current

  def initialize(current)
    @current = current
    @nodes = current.agent.conversations.family_of(current).includes(:agent).order(:created_at, :id).strict_loading.to_a
    @children = @nodes.group_by(&:parent_id)
  end

  def roots = @children.fetch(nil, [])

  def children(node) = @children.fetch(node.id, [])

  # The parent's message the branch was taken after; nil for a branch that
  # started empty.
  def fork_point(node) = fork_points[[ node.parent_id, node.forked_at_entry_id ]]

  def message_count(node) = message_counts.fetch(node.id, 0)

  private
    def ids = @nodes.map(&:id)

    def fork_points
      @fork_points ||= begin
        branches = @nodes.select(&:forked_at_entry_id)
        Message.where(conversation_id: branches.map(&:parent_id), entry_id: branches.map(&:forked_at_entry_id)) # tenancy-ok: conversations reached through the owner's agent
          # A tool's result shares its call's entry; the reply that made the call is the one to show.
          .sort_by { it.role == "toolResult" ? 0 : 1 }.index_by { [ it.conversation_id, it.entry_id ] }
      end
    end

    def message_counts
      @message_counts ||= Message.where(conversation_id: ids, role: %w[ user assistant ]).group(:conversation_id).count # tenancy-ok: conversations reached through the owner's agent
    end
end
