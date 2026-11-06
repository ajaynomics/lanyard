# What a reply, or a whole conversation, used: token counts as the sidecar
# measured them, and a cost at the catalogue's API prices. The sidecar sends a
# reply's cost as a number and the totals' as a labelled estimate
# (docs/design/CONTRACT.md); both are kept the same way here, with nil for a
# cost that is zero or unknown, so the page never shows "$0.00".
module Usage
  COUNTS = %w[ input output cacheRead cacheWrite totalTokens ].freeze

  def self.from(raw)
    return unless raw.is_a?(Hash)
    counts = COUNTS.to_h { [ it, raw[it].is_a?(Numeric) ? raw[it].to_i : 0 ] }
    cost = raw["cost"].is_a?(Hash) ? raw["cost"]["estimatedTotal"] : raw["cost"]
    counts.merge("cost" => (cost.to_f if cost.is_a?(Numeric) && cost.positive?))
  end
end
