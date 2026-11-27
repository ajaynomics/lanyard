require "strscan"

# The receiving mail server's report (RFC 8601), not a check of the signature
# here. A From address alone says nothing about who sent the message.
class MailAuthentication
  RESULT_HEADER = /\AAuthentication-Results[ \t]*:/i
  LABEL = /[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?/
  DOMAIN = /\A#{LABEL}(?:\.#{LABEL})*\z/
  TOKEN = /"(?:[^"\\]|\\.)*"|[^\s();="]+|=/

  def initialize(mail, source: nil)
    @mail, @source = mail, source
  end

  def verified?
    trusted = trusted_receivers
    return false if trusted.empty?
    result = receiver_result or return false
    domain = from_domain or return false
    (id, version, extra), *results = clauses(result)
    return false unless id && !extra && (version.nil? || version == "1") && trusted.include?(unquote(id).downcase)

    results.any? { passes?(it, domain) }
  rescue Mail::Field::ParseError
    false
  end

  private
    # Only the Gmail API reader assigns this provenance; message headers
    # cannot pick the receiver whose results count.
    def trusted_receivers
      return [ "mx.google.com" ] if @source == :gmail
      DurableAssistants.config(:mail, :authserv_id).to_s.downcase.split(",").map(&:strip).reject(&:empty?)
    end

    # Mail reorders parsed fields. Use the original order: the receiver must
    # prepend its Received to everything it accepts, so nothing below that
    # line can vouch for the sender. Only the first result can count, not a
    # later one claiming the same ID.
    def receiver_result
      boundary = headers.index { it.match?(/\AReceived[ \t]*:/i) } or return
      headers.take(boundary).find { it.match?(RESULT_HEADER) }&.sub(RESULT_HEADER, "")
    end

    def headers = @headers ||= @mail.header.raw_source.b.split(Mail::Constants::HEADER_SPLIT)

    def from_domain
      return unless headers.count { it.match?(/\AFrom[ \t]*:/i) } == 1
      addresses = Array(@mail.from)
      return unless addresses.one?
      domain = Mail::Address.new(addresses.first).domain.to_s.downcase
      domain if domain.match?(DOMAIN)
    end

    def passes?(clause, domain)
      method, equals, result, *properties = clause
      return false unless equals == "=" && result&.casecmp?("pass")

      case method.downcase
      when "dmarc", "dmarc/1"
        property(properties, "header.from") == domain
      when "dkim", "dkim/1"
        signer = property(properties, "header.d")
        # No public suffix lookup: accept the same domain or a signer beneath
        # it, never a parent, sibling, or merely a matching string suffix.
        signer && (signer == domain || signer.end_with?(".#{domain}"))
      else false
      end
    end

    def property(tokens, key)
      properties = tokens.each_slice(3).to_a
      return unless properties.all? { |_, equals, value| equals == "=" && value && value != "=" }
      matches = properties.select { |name, _, _| name.casecmp?(key) }
      return unless matches.one?
      value = unquote(matches.first.last).downcase
      value if value.match?(DOMAIN)
    end

    # Comments and quoted values can contain separators or whole fake results.
    # Read them as units; an unfinished one makes the report unusable.
    def clauses(value)
      scanner = StringScanner.new(value.gsub(Mail::Constants::UNFOLD_WS, '\\1'))
      groups = [ [] ]
      until scanner.eos?
        if scanner.skip(/[ \t]+/)
          next
        elsif scanner.skip(/\(/)
          return [] unless skip_comment(scanner)
        elsif scanner.skip(/;/)
          groups << []
        elsif (token = scanner.scan(TOKEN))
          groups.last << token
        else
          return []
        end
      end
      groups
    end

    def skip_comment(scanner)
      depth = 1
      until depth.zero?
        if scanner.skip(/\(/)
          depth += 1
        elsif scanner.skip(/\)/)
          depth -= 1
        elsif !scanner.skip(/\\.|[^()\\]+/)
          return false
        end
      end
      true
    end

    def unquote(value)
      value.start_with?('"') ? value[1...-1].gsub(/\\(.)/, '\\1') : value
    end
end
