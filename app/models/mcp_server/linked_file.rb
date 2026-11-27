# A file a connector's answer links to (Tool::Mcp::FoundFile), fetched only
# from the connector's own origin: the same scheme, host and port as its
# address. A link is the server's to write, so one elsewhere could aim this
# app, and the connector's credentials, at anything it can reach; any other
# address is refused before a request is made. No redirect is followed, and
# outside development the address is pinned to a public one, as every
# request a connector makes is (McpServer::Address).
class McpServer::LinkedFile
  def self.same_origin?(server, link)
    own, link = URI(server.url.to_s), URI(link.to_s)
    link.is_a?(URI::HTTP) && own.is_a?(URI::HTTP) && link.host.present? &&
      [ own.scheme, own.host.downcase, own.port ] == [ link.scheme, link.host.downcase, link.port ]
  rescue URI::InvalidURIError
    false
  end

  def initialize(server)
    @server = server
  end

  # Its bytes, of any size, in a Tempfile for the sidecar to save
  # (Sidecar::FilesController). McpServer::TIMEOUT bounds each read, not the
  # whole: a big file is never cut for being big.
  def download(link)
    raise McpServer::SignInNeeded if @server.gmail_grant? || (@server.google == :gmail && @server.reload.gmail_grant?)

    raise McpServer::Unreachable, "#{@server} linked a file away from its own address, so it wasn't fetched." unless self.class.same_origin?(@server, link)
    uri = URI(link)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.ipaddr = McpServer::Address.public_address(uri.host) if @server.pinned?
    http.open_timeout = http.read_timeout = http.write_timeout = McpServer::TIMEOUT
    http.max_retries = 0
    file = Tempfile.new("connector-file", binmode: true)
    http.start do
      http.request(Net::HTTP::Get.new(uri.request_uri, headers)) do |response|
        raise McpServer::Unreachable, "#{@server} refused the file (#{response.code})." unless response.is_a?(Net::HTTPSuccess)
        response.read_body { file.write(it) }
      end
    end
    whole = file.tap(&:flush).tap(&:rewind)
  rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError, McpServer::Address::Refused => failure
    raise McpServer::Unreachable, "Could not reach #{@server}: #{failure.class.name.demodulize}"
  ensure
    file&.close! unless whole
  end

  private
    # The connector's own: its headers and pasted key, or its sign-in's token.
    def headers
      token = @server.oauth_tokens&.dig("access_token") unless @server.authorized_by_header?
      @server.request_headers.merge(token ? { "Authorization" => "Bearer #{token}" } : {})
    end
end
