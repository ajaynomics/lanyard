class Workspace::Group::Tree
  def initialize(threads, matches, cards)
    @threads = threads.index_by(&:agent_id)
    @tree = Workspace::ReportingTree.new(threads.map(&:agent))
    @cards = cards.map(&:conversation_id).tally
    @shown = matches ? threads.select { matches.include?(it.id) }.map(&:agent_id).to_set : active_paths(threads)
  end

  def roots
    @threads.values.select { @shown.include?(it.agent_id) && !@shown.include?(@tree.manager(it.agent)&.id) }
  end

  def reports(conversation) = listed(@tree.reports_for(conversation.agent))
  def selected_path(conversation) = conversation ? @tree.path(conversation.agent).map(&:id) : []

  def unlisted_manager(conversation)
    manager = @tree.manager(conversation.agent)
    manager unless @shown.include?(manager&.id)
  end

  def depth(conversation) = @tree.path(conversation.agent).size - 1

  def waiting(conversation) = @cards.fetch(conversation.id, 0)

  def waiting_below(conversation)
    reports(conversation).sum { waiting(it) + waiting_below(it) }
  end

  private
    def listed(agents) = agents.filter_map { @threads[it.id] if @shown.include?(it.id) }

    def active_paths(threads)
      threads.reject(&:archived?).flat_map { @tree.path(it.agent).map(&:id) }.to_set
    end
end
