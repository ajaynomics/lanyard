# A workspace's Usage page and payer in words (docs/billing.md).
module ModelUsagesHelper
  # The tools that report usage of their own, as a person knows them.
  TOOL_NAMES = { "web_search" => "Web search", "subagent" => "Helpers" }.freeze

  # Who a workspace's calls are billed to: "the install", or a workspace,
  # a personal one as "Alice (personal)".
  def payer_name(payer)
    if payer.nil? then "the install"
    elsif payer.personal? then "#{payer} (personal)"
    else payer.to_s
    end
  end

  # The choices of payer its owner has: the install, the workspace itself,
  # their other workspaces, and whichever it has now.
  def payer_choices(workspace)
    owned = Current.user.owned_workspaces.personal_first.to_a | [ workspace.payer ].compact
    [ [ "The install", "" ], [ "#{workspace} (this workspace)", workspace.id ],
      *(owned - [ workspace ]).map { [ payer_name(it), it.id ] } ]
  end

  # A line's name on the Usage page: the agent's, as it was named; "Claude
  # Opus 5.5 · Claude subscription" for a model, "Web search" for a tool; or
  # who paid.
  def model_usage_name(by, key)
    case by
    when :agent then key.last
    when :payer then payer_name(key).upcase_first
    when :model
      model, tool = key
      tool ? TOOL_NAMES.fetch(tool) { tool.humanize } : [ ModelCatalog.plain_name(model), ModelCatalog::PROVIDERS[model.split("/").first] ].compact.join(" · ")
    end
  end

  # "1,540 in · 305 out · 900 cache read · about $0.12 at API prices": what
  # was read fresh, written, and read from or written to the prompt cache.
  def model_usage_line(line)
    parts = [ "#{number_with_delimiter(line.input.to_i)} in", "#{number_with_delimiter(line.output.to_i)} out" ]
    parts << "#{number_with_delimiter(line.cache_read)} cache read" if line.cache_read.to_i.positive?
    parts << "#{number_with_delimiter(line.cache_write)} cache write" if line.cache_write.to_i.positive?
    parts << "#{usage_cost(line.cost)} at API prices" if line.cost.to_f.positive?
    parts.join(" · ")
  end
end
