# What a reply, or a whole conversation, used: token counts as the sidecar
# measured them, and a cost at the catalogue's API prices. The sidecar sends a
# reply's cost as a number and the totals' as a labelled estimate
# (docs/design/CONTRACT.md); both are kept the same way here, with nil for a
# cost that is zero or unknown, so the page never shows "$0.00".
module Usage
  COUNTS = %w[ input output cacheRead cacheWrite totalTokens ].freeze
  # The sidecar keeps a row for each model and each tool that reports usage;
  # more than this many in one thread is no real thread.
  ROWS = 64

  def self.from(raw)
    return unless raw.is_a?(Hash)
    counts = COUNTS.to_h { [ it, raw[it].is_a?(Numeric) ? raw[it].to_i : 0 ] }
    cost = raw["cost"].is_a?(Hash) ? raw["cost"]["estimatedTotal"] : raw["cost"]
    counts.merge("cost" => (cost.to_f if cost.is_a?(Numeric) && cost.positive?))
  end

  # Each model's and tool's running total, as the sidecar's totals carry them
  # beside the sum ({"models" => {"anthropic/claude-…" => usage}, "tools" =>
  # {"web_search" => usage}}), for ModelUsage to record what each added. Nil
  # from a sidecar that sends no rows.
  def self.rows(raw)
    return unless raw.is_a?(Hash) && raw["models"].is_a?(Hash)
    %w[ models tools ].to_h do |kind|
      named = raw[kind].is_a?(Hash) ? raw[kind].select { |name, row| name.is_a?(String) && name.length <= 200 && row.is_a?(Hash) } : {}
      [ kind, named.first(ROWS).to_h { |name, row| [ name, from(row).then { it.merge("cost" => it["cost"].to_f) } ] } ]
    end
  end
end
