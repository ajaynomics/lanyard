# One tool on an agent's MCP server. It answers the messages a Tool class answers
# (tool_name, declaration, errors_for, asks, effect, new), so Agent#tools lists it
# and the Invocation ledger runs it like any other tool.
#
# What the server says about a tool is its claim, not ours: only a tool it marks
# read-only runs at once; the MCP spec reads an unmarked tool as destructive, so
# anything else asks the person first. Its results reach the model as data.
class Tool::Mcp
  NAME_LIMIT = 64
  # Bytes of a long answer's start the model reads with the call, as JSON;
  # the whole answer is saved on its computer (Tool::Mcp::LongAnswer). Room
  # is left under DurableAssistants::ResultBytes::ANSWER for the rest.
  SHOWN_BYTES = 44_000

  attr_reader :server, :listing

  def initialize(server, listing)
    @server, @listing = server, listing
  end

  # `mcp__<server>__<tool>`, in the sidecar's alphabet and length.
  def tool_name
    prefix = "mcp__#{server.name}__"
    prefix + listing["name"].to_s.downcase.gsub(/[^a-z0-9_]/, "_").first(NAME_LIMIT - prefix.length)
  end

  def description = listing["description"].to_s.truncate(2_000).presence || listing["name"].to_s

  # The connector it belongs to (Tool::Mcp::Group names its kind).
  def connector = server.name

  def schema
    input = listing["input_schema"].presence || {}
    input.merge("type" => "object", "properties" => input["properties"] || {})
  end

  def declaration = { name: tool_name, description: description, parameters: schema, files: files_declaration }.compact

  # Files on the agent's computer that a call names, which the sidecar reads and
  # hands over first, as for send_email (Tool.reads_files). Only Rails can opt in.
  def files_argument = wiki_upload? ? "attachments" : (listing["reads_files"] if server.own_listing?)
  def files_limits = (Tool::Attaching.limits if files_argument)
  def files_declaration = files_limits&.then { { argument: files_argument, maxBytes: it[:each], maxTotalBytes: it[:total] } }

  def errors_for(values)
    JSONSchemer.schema(schema, regexp_resolver: "ecma").validate(values).map { it["error"] }
  rescue JSONSchemer::UnknownRef, JSONSchemer::UnknownFormat, JSONSchemer::UnknownVocabulary, JSONSchemer::InvalidRefResolution,
         JSONSchemer::InvalidRefPointer, JSONSchemer::InvalidRegexpResolution => error
    [ "#{server} described #{listing["name"]} with a schema that cannot be checked (#{error.class.name.demodulize})" ]
  end

  def asks = read_only? ? nil : :approval
  def read_only? = listing.dig("annotations", "readOnlyHint") == true

  # A tool of this app's own listing may ask a person every time, even where the
  # install approves everything (McpServer::Google): what a server lists cannot.
  # So does any tool that may write, on a connector its owner set to ask before
  # every write: an answer for one call never covers the next.
  def even_approving_everything? = (server.own_listing? && listing["asks_every_time"] == true) || asks_every_write?
  def asks_every_write? = server.asks_every_write? && !read_only?
  def every_time? = even_approving_everything?
  def always? = !every_time?
  # An event tool that asks every time when a call reaches other people (McpServer::Google#reaches_others?).
  def asks_with_guests? = server.own_listing? && listing["asks_with_guests"] == true
  # A share that asks every time when it reaches outside the account's own domain.
  def asks_outside? = server.own_listing? && listing["asks_outside"] == true
  def asks_every_time_for?(arguments) =
    even_approving_everything? || ((asks_with_guests? || asks_outside?) && McpServer::Google.new(server).reaches_others?(listing["name"], arguments))

  # Whether a call's answer names a file the sidecar saves on the agent's
  # computer (Invocation#file?): one of Google's file tools, or the office's
  # wiki fetching an attachment (McpServer::WikiAttachment).
  def finds_file?(arguments)
    server.google ? McpServer::Google::FILES.include?(listing["name"]) : McpServer::WikiAttachment.fetch?(server, listing["name"], arguments)
  end

  def wiki_upload? = listing["name"] == McpServer::WikiUpload::NAME && McpServer::WikiUpload.enabled?(server)

  def label = "#{listing['name'].to_s.humanize(capitalize: false)} (#{server})"

  # A card for a connector that asks before every write says which connector,
  # and so which account, the call acts as, and why it has no "Always".
  def approval_title(_arguments) = ("Allow #{listing['name'].to_s.humanize(capitalize: false)} as #{server}?" if asks_every_write?)
  def approval_note(_arguments) = ("#{server} is set to ask before every write, so this asks every time." if asks_every_write?)

  # The call leaves this database, so the ledger records the row before it runs.
  def effect = :external

  def new(invocation) = Call.new(invocation, self)

  # Gmail's send_message is named as send_email's mail is, and is looked for
  # the same way: by Message-ID, in a Sent folder.
  def self.dispatch_words(arguments) = Tool::SendEmail.dispatch_words(arguments)
  def self.dispatches_mail? = true

  # A connector's own send whose answer never came (Dispatch#check): that
  # connector's Sent, searched for the message's Message-ID alone. Gmail's
  # send_message is the one such send. Its Message-ID when found, nil when not.
  def self.find_dispatched(dispatch)
    tool = dispatch.conversation.tool(dispatch.tool_name)
    raise Dispatch::LookupFailed, "#{dispatch.tool_name} is no longer connected" unless tool.is_a?(Tool::Mcp) && tool.server.google
    dispatch.provider_id if McpServer::Google.new(tool.server).sent_id(dispatch.provider_id)
  rescue DurableAssistants::Google::Error, McpServer::Unreachable => problem
    raise Dispatch::LookupFailed, problem.message
  end

  # One call of the tool, made for an invocation.
  class Call < Tool
    include Tool::Attaching
    include Tool::SendsMailOnce

    def initialize(invocation, tool)
      super(invocation)
      @tool = tool
    end

    def asks = @tool.asks
    def even_approving_everything? = @tool.asks_every_time_for?(arguments)
    # A draft's id says nothing of what it holds, and the agent can change the
    # draft after the card is made, so the card shows the draft itself.
    # A call with files shows their names and sizes, bound to their bytes.
    def previews? = attaching? || (@tool.server.google.present? && @tool.listing["name"] == "send_draft")

    def preview
      return McpServer::Google.new(@tool.server).preview(@tool.listing["name"], arguments) unless @tool.files_argument
      found = attached_files
      return { "error" => "#{File.basename(missing(found))} didn't arrive from the computer. Ask the agent to send again." } if missing(found)
      files = { "attachments" => attachments_shown(found), "digest" => attachments_digest(found) }
      return files if @tool.wiki_upload?

      arguments.slice("to", "cc", "bcc", "subject", "body").merge(files)
    end

    def details(values)
      return unless @tool.wiki_upload? && invocation.preview
      values.slice("name", "content_type").merge(invocation.preview.slice("attachments"))
    end

    def every_time? = even_approving_everything?
    def always? = !every_time?
    def attaching? = @tool.files_argument.present? && attached_paths.any?

    # The connector's own tool, called directly, or as one
    # account of a Tool::Mcp::Group: an "Always" stays with that connector.
    def permission_name = @tool.tool_name

    # Whom Gmail's send_message mails now. A draft sent by its id names nobody
    # until it is fetched, so send_draft is not checked here.
    def contacts = @tool.server.google && @tool.listing["name"] == "send_message" ? arguments.values_at("to", "cc", "bcc").flatten.compact : []

    def call(**arguments)
      return upload_to_wiki(arguments) if @tool.wiki_upload?
      arguments = with_files(arguments) if @tool.files_argument
      return send_mail_once(arguments) if McpServer::Google.new(@tool.server).sends_mail?(@tool.listing["name"])
      result = @tool.server.call_tool(@tool.listing["name"], arguments, conversation: conversation)
      raise Refusal, "#{@tool.tool_name} failed: #{text_of(result["content"]).presence || 'no reason given'}".truncate(1_000) if result["isError"]

      images = []
      remaining = Array(result["content"]).reject do |block|
        images << block.slice("type", "mimeType", "data") if images.size < Conversation::IMAGES_PER_MESSAGE && inline_image?(block)
      end
      answer = result["structuredContent"].is_a?(Hash) ? result["structuredContent"] : { text: text_of(remaining) }
      fitted = fit_answer(answer, result, arguments)
      images.empty? ? fitted : [ fitted, images ]
    # Only the person can sign in, so the agent is told to ask them rather than try again.
    rescue McpServer::SignInNeeded
      raise Refusal, "#{@tool.server} needs the person to sign in again, on its Connectors page. Tell them; don't retry until they have."
    rescue McpServer::Unreachable => problem
      raise Refusal, problem.message
    end

    private
      def fit_answer(answer, result, arguments)
        return McpServer::WikiAttachment.new(@tool.server).mark(answer) if wiki_attachment?
        return answer if @tool.finds_file?(arguments)

        found = FoundFile.new(invocation, @tool.server).describe(result)
        fitted = LongAnswer.new(invocation, @tool.listing["name"]).fit(answer)
        return fitted if found.empty?
        fitted = fitted.deep_stringify_keys
        saved = found["found_files"].to_a + fitted["found_files"].to_a
        fitted.merge(found).merge("found_files" => saved.presence, "note" => [ found["note"], fitted["note"] ].compact.join(" ").presence).compact
      end

      def inline_image?(block)
        type, data = block.values_at("mimeType", "data")
        return false unless block["type"] == "image" && Conversation::IMAGE_TYPES.key?(type) && data.is_a?(String)
        return false if data.bytesize > ((Conversation::IMAGE_BYTES + 2) / 3) * 4

        bytes = Base64.strict_decode64(data)
        bytes.bytesize <= Conversation::IMAGE_BYTES && Marcel::MimeType.for(StringIO.new(bytes)) == type
      rescue ArgumentError
        false
      end

      # Gmail's send_message, sent once, as send_email is (Tool::SendsMailOnce),
      # from the connector's account: its Message-ID is the app's own.
      def send_mail_once(arguments)
        to = Array(arguments[:to])
        parts = [ arguments.except(:files).sort.to_h.to_json, (attachments_digest(attached_files) if @tool.files_argument) ]
        send_once(to: to, sender: @tool.server.name, domain: URI(DurableAssistants.config(:app, :url).to_s).host.presence || "localhost",
          tool_name: @tool.tool_name, parts: parts, dispatch_recorder: invocation.gmail_reply_dispatch_recorder(@tool.server)) do |message_id|
          result = @tool.server.call_tool(@tool.listing["name"], arguments.merge(message_id: message_id, replying: invocation.gmail_replying),
            conversation: conversation)
          raise Refusal, "#{@tool.tool_name} failed: #{text_of(result["content"]).presence || 'no reason given'}".truncate(1_000) if result["isError"]
          result["structuredContent"]
        rescue DurableAssistants::Google::Unanswered => problem
          raise Unanswered, problem.message
        end
      end

      def sent_folder?(_dispatch) = true
      def find_dispatched(dispatch) = Tool::Mcp.find_dispatched(dispatch)

      def attaching_arguments = arguments
      def wiki_attachment? = McpServer::WikiAttachment.fetch?(@tool.server, @tool.listing["name"], arguments)

      def upload_to_wiki(arguments)
        McpServer::WikiUpload.new(@tool.server).upload(received_files.sole, **arguments.except(:attachments), conversation: conversation)
      end

      def with_files(arguments)
        arguments.except(:attachments).merge(files: received_files.map { [ it.name, it.file.download ] })
      end

      # One missing file stops the call, named by its file name alone.
      def received_files
        found = attached_files
        raise Refusal, "#{File.basename(missing(found))} didn't arrive from your computer, so nothing was sent or saved. Send again." if missing(found)
        found
      end

      # Anything not shown as text or handed off as a picture is named, not inlined.
      def text_of(content)
        Array(content).map do |block|
          case block["type"]
          when "text" then block["text"].to_s
          when "resource" then block.dig("resource", "text") || "[resource #{block.dig('resource', 'uri')}]"
          else "[#{block['type']} #{block['mimeType']}]".squish
          end
        end.join("\n\n")
      end
  end
end
