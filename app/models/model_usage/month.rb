# A month of a workspace's model usage as its Usage page shows it: the sum,
# then lines by agent, by model or tool, and by who paid. Read from the
# records alone, never from today's settings.
class ModelUsage::Month
  SUMS = %w[ input output cache_read cache_write total_tokens cost ].freeze
  Line = Data.define(:key, *SUMS.map(&:to_sym))

  attr_reader :starts

  def initialize(usages, starts:)
    @usages, @starts = usages, starts.beginning_of_month
  end

  def total = Line.new(nil, *records.pick(*sums))
  def none? = !records.exists?

  # Keyed by [agent id, its name then], so an agent removed since still has its line.
  def by_agent = lines(:agent_id, :agent_name)
  # Keyed by [model, tool]: one of the two.
  def by_model = lines(:model, :tool)
  # Keyed by the paying workspace, nil for the install.
  def by_payer
    paid = lines(:payer_id)
    payers = Workspace.where(id: paid.filter_map(&:key)).index_by(&:id) # tenancy-ok: the workspaces its owner chose to bill, named on its page
    paid.map { it.with(key: payers[it.key]) }
  end

  private
    def records = @usages.during(starts.all_month)

    def lines(*columns)
      records.group(*columns).order(ModelUsage.arel_table[:total_tokens].sum.desc).pluck(*columns, *sums)
        .map { |row| Line.new(columns.one? ? row.first : row.first(columns.size), *row.drop(columns.size)) }
    end

    def sums = SUMS.map { ModelUsage.arel_table[it].sum }
end
