module ApplicationHelper
  MARKDOWN_TAGS = %w[ p br strong em del a code pre blockquote ul ol li h1 h2 h3 h4 h5 h6 hr table thead tbody tr th td ].freeze
  MARKDOWN_ATTRIBUTES = %w[ href lang ].freeze

  # Model output is untrusted: raw HTML is dropped by the renderer, and what it
  # produces is sanitized again to a small allow-list.
  def markdown(text)
    html = Commonmarker.to_html(text.to_s, options: { render: { unsafe: false }, extension: { table: true, strikethrough: true, autolink: true } },
      plugins: { syntax_highlighter: nil })
    sanitize(html, tags: MARKDOWN_TAGS, attributes: MARKDOWN_ATTRIBUTES)
  end

  # One reply's usage, for a muted line under it: "1,204 in · 312 out · about
  # $0.02 at API prices". Tokens in count the cached prompt too. A cost shows
  # only when the model has prices; it is an estimate, not a bill.
  def usage_line(usage)
    return if usage.blank? || usage["totalTokens"].to_i.zero?
    tokens_in = usage.values_at("input", "cacheRead", "cacheWrite").sum(&:to_i)
    parts = [ "#{number_with_delimiter(tokens_in)} in", "#{number_with_delimiter(usage["output"].to_i)} out" ]
    parts << "#{usage_cost(usage["cost"])} at API prices" if usage["cost"]
    parts.join(" · ")
  end

  # "about $0.02", or "under $0.01" where "about" would be wrong.
  def usage_cost(cost)
    cost < 0.01 ? "under $0.01" : "about #{number_to_currency(cost)}"
  end

  # A tool's name as the person reads it: "Ran remember note", "Running code…".
  def tool_label(name)
    name.to_s == "codemode" ? "code" : name.to_s.humanize(capitalize: false)
  end
end
