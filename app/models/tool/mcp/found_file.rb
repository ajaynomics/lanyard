# Every file in a connector's answer is saved on the agent's computer, as a
# Gmail attachment is (Invocation#file?, agent/files.mjs): MCP's embedded
# resource with its bytes (`{type: "resource", resource: {uri, mimeType,
# blob}}`), or a link to one (`{type: "resource_link", uri, name, mimeType}`).
# Each is listed in found_files, and the model reads its name, type and size,
# and where it was saved. Embedded bytes wait on the call
# (Invocation#hold_file); a link is fetched when the sidecar asks, and only
# from the connector's own address (McpServer::LinkedFile).
class Tool::Mcp::FoundFile
  def initialize(invocation, server)
    @invocation, @server = invocation, server
  end

  # What the answer says of its files (found_files, and those not_saved with
  # a note saying why), or an empty hash when it carried none.
  def describe(result)
    blocks = Array(result["content"]).select { embedded?(it) || it["type"] == "resource_link" }
    saved, unsaved, notes = [], [], []
    blocks.each do |block|
      if block["type"] == "resource_link" && !McpServer::LinkedFile.same_origin?(@server, block["uri"])
        notes << "#{@server} linked a file at #{where(block["uri"])}, not at the connector's own address, so it was not fetched."
      elsif (file = embedded?(block) ? embedded(block["resource"]) : linked(block))
        @invocation.agent.saves_files? ? saved << file : unsaved << file.except(:held, :link)
      else
        notes << "#{@server} sent a file whose bytes couldn't be read, so it was not saved."
      end
    end
    notes << "This agent has no computer of this app's to save files on, so those in not_saved were not saved." if unsaved.any?
    { found_files: saved.presence, not_saved: unsaved.presence, note: notes.uniq.join(" ").presence }.compact.deep_stringify_keys
  end

  private
    def embedded?(block) = block["type"] == "resource" && block.dig("resource", "blob").is_a?(String)

    def embedded(resource)
      bytes = Base64.strict_decode64(resource["blob"])
      file = described(name_in(resource["uri"]), resource["mimeType"], bytes.bytesize)
      return file unless @invocation.agent.saves_files?
      file.merge(held: @invocation.hold_file(io: StringIO.new(bytes), filename: file[:name], content_type: file[:type]))
    rescue ArgumentError
      nil
    end

    def linked(block) = described(block["name"].presence || name_in(block["uri"]), block["mimeType"], block["size"]).merge(link: block["uri"])

    def described(name, type, size) =
      { name: DurableAssistants::Google.safe_name(name), type: type.presence || "application/octet-stream", size: size&.to_i }.compact

    def where(link)
      URI(link.to_s).then { it.host.presence || "a #{it.scheme} address" }
    rescue URI::InvalidURIError
      "an address that isn't one"
    end

    def name_in(uri)
      URI(uri.to_s).path.to_s.split("/").last.presence || "file"
    rescue URI::InvalidURIError
      "file"
    end
end
