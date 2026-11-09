module ApplicationHelper
  # The deployment's name, from APP__NAME, for its screens.
  def app_name = DurableAssistants.config(:app, :name)

  MARKDOWN_TAGS = %w[ p br strong em del a code pre span blockquote ul ol li h1 h2 h3 h4 h5 h6 hr table thead tbody tr th td sup section input ].freeze
  MARKDOWN_ATTRIBUTES = %w[ href lang class title target rel type checked disabled ].freeze
  URL = %r{\bhttps?://[^\s<>"]+}
  SHOWN_URL = 40 # characters of a bare link shown, the rest in its title

  # Model output is untrusted: raw HTML is dropped by the renderer, and what it
  # produces is sanitized again to a small allow-list. A fenced block in a
  # language the highlighter knows comes back as spans named by the grammar's
  # scopes (an empty theme), which components.css colours from the tokens;
  # a class can only come from the renderer, since raw HTML never gets through.
  # No heading anchors: the sanitizer would leave each an empty, unnamed link.
  def markdown(text)
    html = Commonmarker.to_html(text.to_s, options: { render: { unsafe: false },
      extension: { table: true, strikethrough: true, autolink: true, tasklist: true, footnotes: true, header_ids: nil } },
      plugins: { syntax_highlighter: { theme: "" } })
    sanitize(readable(html), tags: MARKDOWN_TAGS, attributes: MARKDOWN_ATTRIBUTES)
  end

  # Words a person or a channel sent, kept exactly as they are (the composer
  # and the echo read them back), with their links live.
  def linked(text)
    safe_join(text.to_s.split(/(#{URL})/o).each_slice(2).flat_map do |words, url|
      next [ words ] unless url
      url, after = url_and_after(url)
      [ words, link_to(url, url, target: "_blank", rel: "noopener noreferrer"), after ]
    end)
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

  # How full the model's context is, as pi's footer says it, and where earlier
  # messages are summarised: "Context 42%: 84k of 200k, summarised at 160k",
  # or "84k of 262k before summarising" when the model's size is unknown.
  # Measured by each reply, so after a summary it waits for the next one.
  def context_meter(conversation)
    return "Summarised; measured after the next reply" if conversation.summarised_since_last_reply?
    return unless (tokens = conversation.context_tokens) && (compact_at = ModelCatalog.compact_at(conversation.agent.model))
    if (window = ModelCatalog.context_window(conversation.agent.model))
      "Context #{percent(tokens.fdiv(window))}: #{thousands(tokens)} of #{thousands(window)}, summarised at #{thousands(compact_at)}"
    else
      "#{thousands(tokens)} of #{thousands(compact_at)} before summarising"
    end
  end

  # "Notes file: AGENTS.md, 3 KB", and why one too large was not read.
  def notes_file_line(bytes)
    size = bytes < 1.kilobyte ? "under 1 KB" : "#{(bytes / 1024.0).ceil} KB"
    too_large = ", too large to read (up to #{Computer::NOTES_FILE_LIMIT / 1.kilobyte} KB)" if bytes > Computer::NOTES_FILE_LIMIT
    "Notes file: AGENTS.md, #{size}#{too_large}"
  end

  # "900", "84k", "1M", "1.05M".
  def thousands(tokens)
    if tokens < 1_000 then tokens.to_s
    elsif tokens < 1_000_000 then "#{(tokens / 1_000.0).round}k"
    else "#{number_with_precision(tokens / 1_000_000.0, precision: 2, strip_insignificant_zeros: true)}M"
    end
  end

  # Why a run stopped, in words a person can act on.
  def failure_text(reason)
    case reason
    when "compaction_failed" then "couldn't summarise earlier messages. Type /compact to try again."
    when "rate_limited" then "the model's usage limit is reached. Try again later, or switch subscription in settings."
    when "computers_busy" then "too many computers are awake; try again shortly."
    when "stalled" then "the agent stopped making progress, so its turn was ended. Send your message again."
    when "credential_missing" then "this model isn't signed in, or its sign-in can't be opened. Sign in again on the Subscriptions page, or save an API key there."
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

  private
    # What the renderer makes, as a thread reads it: a link leaves the app in
    # a new tab, a bare one shows its address short; a picture from elsewhere
    # is a link to it, never loaded; a footnote is its number, its note below,
    # with no anchors to clash between replies on one page; a task's box
    # can't be ticked here.
    def readable(html)
      fragment = Nokogiri::HTML5.fragment(html)
      fragment.css("img").each { it.replace(fragment.document.create_element("a", "Picture: #{it["alt"].presence || it["src"]}", href: it["src"])) }
      fragment.css("a[data-footnote-ref]").each { it.replace(it.text) }
      fragment.css("a[data-footnote-backref]").each(&:remove)
      fragment.css("[id]").each { it.remove_attribute("id") }
      fragment.css("input").each { it["type"], it["disabled"] = "checkbox", "" }
      fragment.css("a[href^='http://'], a[href^='https://']").each do |link|
        link["target"], link["rel"] = "_blank", "noopener noreferrer"
        link.content, link["title"] = short_url(link["href"]), link["href"] if [ link.text, "http://#{link.text}" ].include?(link["href"])
      end
      fragment.to_html
    end

    # A sentence's last mark isn't the link's, nor a closing bracket the link
    # didn't open: "(see https://example.com/a_(b))." links .../a_(b).
    def url_and_after(url)
      after = +""
      while url.match?(/[.,;:!?'"\])]\z/) && !(url.end_with?(")") && url.count("(") >= url.count(")"))
        after.prepend(url[-1])
        url = url[0..-2]
      end
      [ url, after ]
    end

    def short_url(url) = url.sub(%r{\Ahttps?://(www\.)?}, "").delete_suffix("/").truncate(SHOWN_URL, omission: "…")
end
