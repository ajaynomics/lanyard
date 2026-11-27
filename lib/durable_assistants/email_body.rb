module DurableAssistants
  # The same plain text and HTML alternatives for SMTP and Gmail.
  class EmailBody
    DESCRIPTION = "Plain text. Use line breaks between lines and a blank line between paragraphs."
    TEXT_ENCODING = "base64"

    # Bound HTML nesting; further markers stay visible as text.
    QUOTE_PREFIX = /\A(?:>(?=[ >]|\z) ?){1,8}/.freeze

    def initialize(text)
      @text = text
    end

    # Mail normalizes line endings when it encodes unencoded text. Encode first
    # so that a client decoding the plain part gets the original bytes.
    def encoded_text = Base64.encode64(@text)

    def html
      lines = String.new(@text).gsub(/\r\n?/, "\n").split("\n", -1)
      depth = 0
      fragments = []
      lines.map { |line| quote_line(line) }.chunk(&:first).each do |level, group|
        fragments << ("</blockquote>" * (depth - level)).html_safe if level < depth
        fragments << ("<blockquote>" * (level - depth)).html_safe if level > depth
        depth = level

        text = group.map(&:last).join("\n")
        fragments << paragraphs(text) unless text.blank?
      end
      fragments << ("</blockquote>" * depth).html_safe if depth.positive?
      fragments.empty? ? paragraphs(@text) : ActionController::Base.helpers.safe_join(fragments, "\n")
    end

    private
      def quote_line(line)
        prefix = line[QUOTE_PREFIX]
        prefix ? [ prefix.count(">"), line.delete_prefix(prefix) ] : [ 0, line ]
      end

      def paragraphs(text)
        ActionController::Base.helpers.simple_format(ERB::Util.html_escape(String.new(text)), {}, sanitize: false)
      end
  end
end
