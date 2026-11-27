# Outline's form points to its public address, which may sit behind a sign-in
# gate that shows a page instead of storing the file. Only its path and
# routing headers are used; the bytes go to the same connector that prepared
# the signed form.
class McpServer::WikiUpload
  SOURCE = "create_attachment"
  NAME = "upload_attachment"
  PATH = "/api/files.create"
  CONFIRMATION_BYTES = 4.kilobytes
  LISTING = {
    "name" => NAME,
    "description" => "Upload one file from your computer to the wiki. Returns the attachment URL to put in a document. " \
      "Call directly or from a codemode script so the file can be handed over.",
    "input_schema" => {
      "additionalProperties" => false, "required" => %w[ attachments ], "properties" => {
        "attachments" => Tool::Attaching::ARGUMENT.merge("minItems" => 1, "maxItems" => 1, "description" => "One path on your computer, in a list."),
        "name" => { "type" => "string", "minLength" => 1, "maxLength" => 255, "description" => "Optional filename; defaults to the file's name." },
        "content_type" => { "type" => "string", "maxLength" => 255, "pattern" => "^[a-zA-Z0-9!#$%&'*+.^_`|~-]+/[a-zA-Z0-9!#$%&'*+.^_`|~-]+$",
          "description" => "Optional MIME type, without parameters; defaults to the filename's type." }
      }
    }
  }.freeze

  def self.enabled?(server)
    server.url.present? && McpServer.install_entries.dig(server.install, :uploads_attachments) == true
  end

  def initialize(server)
    @server = server
  end

  def upload(file, conversation:, name: nil, content_type: nil)
    name = ActiveStorage::Filename.new(name || file.name).sanitized
    content_type ||= Rack::Mime.mime_type(File.extname(name).downcase)
    file.file.open do |io|
      upload = prepare({ name: name, contentType: content_type, size: io.size }, conversation)
      post(upload.fetch("uploadUrl"), upload.fetch("form"), [ "file", io, { filename: name, content_type: content_type } ])
      upload.fetch("attachment").slice("url", "id", "name", "size")
    end
  rescue ActiveStorage::FileNotFoundError, ActiveStorage::IntegrityError
    raise McpServer::Unreachable, "Couldn't read the file for #{@server}, so nothing was uploaded.", cause: nil
  end

  private
    def prepare(arguments, conversation)
      result = @server.call_tool(SOURCE, arguments, conversation: conversation)
      raise McpServer::Unreachable, "#{@server} couldn't prepare the upload." if result["isError"]
      answer = described(result)
      raise McpServer::Unreachable, "#{@server} didn't describe the upload." unless answer.is_a?(Hash)
      raise McpServer::Unreachable, "#{@server} can't upload this attachment: only POST uploads to the wiki are supported." unless answer["mode"] == "post"

      limit = answer["maxUploadSize"]
      unless limit.is_a?(Integer) && limit >= 0 && answer["uploadUrl"].is_a?(String) && signed_fields?(answer["form"]) && attachment?(answer["attachment"])
        raise McpServer::Unreachable, "#{@server} didn't describe the upload."
      end
      if arguments.fetch(:size) > limit
        raise McpServer::Unreachable, "This file is larger than #{@server}'s upload limit of #{ActiveSupport::NumberHelper.number_to_human_size(limit)}."
      end
      answer
    end

    def described(result)
      content = result["content"]
      item = content.first if content.is_a?(Array) && content.one?
      JSON.parse(item["text"]) if item.is_a?(Hash) && item["type"] == "text" && item["text"].is_a?(String)
    rescue JSON::ParserError
      nil
    end

    def signed_fields?(fields)
      fields.is_a?(Hash) && fields["sig"].present? && !fields.key?("file") &&
        fields.all? { |key, value| key.match?(/\A[\w.-]+\z/) && value.is_a?(String) }
    end

    def attachment?(record)
      record.is_a?(Hash) && record.values_at("url", "id", "name").all? { |value| value.is_a?(String) && value.present? } &&
        record["size"].to_s.match?(/\A\d+\z/)
    end

    def post(url, fields, file_part)
      link = URI(url)
      unless link.is_a?(URI::HTTP) && link.host.present? && link.userinfo.nil? && link.path == PATH
        raise McpServer::Unreachable, "#{@server} gave a link that isn't an upload."
      end

      address = URI(@server.url)
      http = Net::HTTP.new(address.host, address.port, nil)
      http.use_ssl = address.scheme == "https"
      http.ipaddr = McpServer::Address.public_address(address.host) if @server.pinned?
      http.open_timeout = http.read_timeout = http.write_timeout = McpServer::TIMEOUT
      http.max_retries = 0

      # The signature authenticates the form; the MCP bearer is not needed here.
      request = Net::HTTP::Post.new(PATH, "Host" => link.host, "X-Forwarded-Proto" => link.scheme)
      request.set_form(fields.to_a << file_part, "multipart/form-data")
      http.start do
        http.request(request) { |response| confirm_upload(response) }
      end
    rescue URI::InvalidURIError
      raise McpServer::Unreachable, "#{@server} gave a link that isn't an upload.", cause: nil
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError, Net::HTTPBadResponse,
           Net::HTTPHeaderSyntaxError, McpServer::Address::Refused => failure
      raise McpServer::Unreachable, "Could not reach #{@server}: #{failure.class.name.demodulize}", cause: nil
    end

    def confirm_upload(response)
      raise McpServer::Unreachable, "#{@server} refused the upload (#{response.code})." unless response.is_a?(Net::HTTPOK)
      unconfirmed! unless response.content_type&.casecmp?("application/json")

      # Outline's acknowledgement is tiny; don't buffer an arbitrary response.
      body = +"".b
      response.read_body do |chunk|
        unconfirmed! if body.bytesize + chunk.bytesize > CONFIRMATION_BYTES
        body << chunk
      end
      receipt = JSON.parse(body)
      unconfirmed! unless receipt.is_a?(Hash) && receipt["success"] == true
    rescue JSON::ParserError
      unconfirmed!
    end

    def unconfirmed!
      raise McpServer::Unreachable, "#{@server} didn't confirm the upload.", cause: nil
    end
end
