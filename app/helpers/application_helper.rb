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

  # A tool's name as the person reads it: "Ran remember note", "Running code…".
  def tool_label(name)
    name.to_s == "codemode" ? "code" : name.to_s.humanize(capitalize: false)
  end
end
