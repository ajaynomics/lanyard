# An attachment the office's wiki (Outline) fetched for an agent, saved on
# the agent's computer as a Gmail attachment is (Invocation#file?,
# agent/files.mjs). The wiki's answer names the file and gives a short-lived
# link on the wiki's public address, which an agent's computer can't reach.
# The app fetches it instead, from the connector's own address inside the
# host: only the link's path and query are used, so the request, and the
# connector's key with it, never goes to the host the link names, and only
# the wiki's download paths are asked for.
class McpServer::WikiAttachment
  PATHS = %w[ /api/files.get /api/attachments.redirect ].freeze

  # A local connector only opts in through the install's own configuration.
  def self.fetch?(server, name, arguments)
    name == "fetch" && arguments.to_h.stringify_keys["resource"] == "attachment" &&
      McpServer.install_entries.dig(server.install, :fetches_attachments) == true
  end

  # The wiki's description of the attachment, from its answer: structured,
  # or as JSON text. Nil for an answer that isn't one.
  def self.described(answer)
    answer = answer.to_h.stringify_keys
    found = answer.key?("text") ? JSON.parse(answer["text"].to_s) : answer
    found if found.is_a?(Hash) && found["signedUrl"].present?
  rescue JSON::ParserError
    nil
  end

  def initialize(server)
    @server = server
  end

  # The fetch's answer, saying what the file is, as Google's file tools do.
  def mark(answer)
    found = self.class.described(answer) or return answer
    answer.merge(DurableAssistants::Google.file(name: found["name"], type: found["contentType"], size: found["size"]))
  end

  # Its bytes, of any size, in a Tempfile for the sidecar to save
  # (Sidecar::FilesController). The wiki is asked again, as the first link
  # may have lapsed.
  def download(arguments, conversation:)
    found = self.class.described(answer(@server.call_tool("fetch", arguments, conversation: conversation)))
    raise McpServer::Unreachable, "#{@server} no longer describes the attachment." unless found
    bytes(URI(found["signedUrl"].to_s))
  rescue URI::InvalidURIError
    raise McpServer::Unreachable, "#{@server} gave a link that isn't one."
  end

  private
    # Redirects are followed once, and only on the link's own host: they go
    # to the connector's address too. One elsewhere (a file store, say) is
    # refused. McpServer::TIMEOUT bounds each wait for bytes (connecting, the
    # headers, each read), never the whole: a big file is never cut for being
    # big, and a server silent for that long is given up on.
    def bytes(link, hops: 1)
      raise McpServer::Unreachable, "#{@server} gave a link that isn't a download." unless PATHS.include?(link.path)
      response, body = get(link)
      case response
      when Net::HTTPSuccess then body
      when Net::HTTPRedirection
        onward = link.merge(response["Location"].to_s)
        raise McpServer::Unreachable, "#{@server} sent the download elsewhere, so it wasn't fetched." unless hops.positive? && onward.host == link.host
        bytes(onward, hops: hops - 1)
      else raise McpServer::Unreachable, "#{@server} refused the download (#{response.code})."
      end
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => failure
      raise McpServer::Unreachable, "Could not reach #{@server}: #{failure.class.name.demodulize}"
    end

    # The link's path and query, sent to the connector's address. The wiki
    # knows itself by its public name, so that goes in the Host header.
    def get(link)
      address = URI(@server.url)
      request = Net::HTTP::Get.new(link.request_uri, @server.request_headers.merge("Host" => link.host, "X-Forwarded-Proto" => link.scheme))
      Net::HTTP.start(address.host, address.port, use_ssl: address.scheme == "https", max_retries: 0,
        open_timeout: McpServer::TIMEOUT, read_timeout: McpServer::TIMEOUT, write_timeout: McpServer::TIMEOUT) do |http|
        http.request(request) do |response|
          body = read(response) if response.is_a?(Net::HTTPSuccess)
          # A normal block exit makes Net::HTTP drain redirect/error bodies.
          return [ response, body ]
        end
      end
    end

    # Written to a Tempfile as it arrives, never held whole.
    def read(response)
      file = Tempfile.new("wiki-attachment", binmode: true)
      response.read_body { file.write(it) }
      whole = file.tap(&:flush).tap(&:rewind)
    ensure
      # Gone with any failure, a timeout's included.
      file&.close! unless whole
    end

    # A raw MCP result as Tool::Mcp::Call reads it.
    def answer(result)
      raise McpServer::Unreachable, "#{@server} couldn't fetch the attachment." if result["isError"]
      return result["structuredContent"] if result["structuredContent"].is_a?(Hash)
      { "text" => Array(result["content"]).filter_map { it["text"] if it["type"] == "text" }.join("\n\n") }
    end
end
