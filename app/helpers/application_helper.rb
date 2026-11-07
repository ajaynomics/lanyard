module ApplicationHelper
  # The deployment's name, from APP__NAME, for its screens.
  def app_name = DurableAssistants.config(:app, :name)

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

  # How full the model's context is, against where earlier messages are
  # summarised: "84k of 262k before summarising". Measured by each reply, so
  # after a summary it waits for the next one.
  def context_meter(conversation)
    return "Summarised; measured after the next reply" if conversation.summarised_since_last_reply?
    return unless (tokens = conversation.context_tokens) && (compact_at = ModelCatalog.compact_at(conversation.agent.model))
    "#{thousands(tokens)} of #{thousands(compact_at)} before summarising"
  end

  # "Notes file: AGENTS.md, 3 KB", and why one too large was not read.
  def notes_file_line(bytes)
    size = bytes < 1.kilobyte ? "under 1 KB" : "#{(bytes / 1024.0).ceil} KB"
    too_large = ", too large to read (up to #{Computer::NOTES_FILE_LIMIT / 1.kilobyte} KB)" if bytes > Computer::NOTES_FILE_LIMIT
    "Notes file: AGENTS.md, #{size}#{too_large}"
  end

  def thousands(tokens) = tokens < 1_000 ? tokens.to_s : "#{(tokens / 1_000.0).round}k"

  # Why a run stopped, in words a person can act on.
  def failure_text(reason)
    case reason
    when "compaction_failed" then "couldn't summarise earlier messages. Type /compact to try again."
    when "rate_limited" then "the model's usage limit is reached. Try again later, or switch subscription in settings."
    when "computers_busy" then "too many computers are awake; try again shortly."
    when "credential_missing" then "this model isn't connected. Sign in to its subscription, or save its API key, on the Subscriptions page."
    else reason.to_s.tr("_", " ")
    end
  end

  # A tool's name as the person reads it: "Ran remember note", "Running code…".
  # "code" for a code mode script, "helper" for a sub-agent; an MCP tool reads as its own name with its
  # server after it: "read wiki structure (deepwiki)". use_tool reads as the tool it calls.
  def tool_label(name, arguments = nil)
    case name.to_s
    when "use_tool" then arguments.is_a?(Hash) && arguments["name"].is_a?(String) ? tool_label(arguments["name"]) : "use tool"
    when "codemode" then "code"
    when "subagent" then "helper"
    when /\Amcp__([a-z0-9]+(?:_[a-z0-9]+)*)__(.+)\z/ then "#{$2.humanize(capitalize: false)} (#{$1})"
    else name.to_s.humanize(capitalize: false)
    end
  end
end
