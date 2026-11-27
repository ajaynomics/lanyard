# A Clio Manage account, read through Clio's API v4 (DurableAssistants::Clio)
# and answered here, as Google's and X's are. Its OAuth app is the person's
# own, made in Clio's developer portal: its client ID and secret are the
# username and password of a vault entry the connector names (vault_entry),
# read for each sign-in and renewal and never kept, as an agent's mail
# account reads its password. The sign-in itself, the access and refresh
# tokens, is kept on the connector, encrypted (McpServer::Authorization), and
# never reaches an agent.
#
# It reads matters, contacts, custom fields, documents (described, never
# downloaded) and calendars. Its one write, a calendar entry, asks the person
# every time, even where the install approves everything (EVERY_TIME).
class McpServer::Clio
  Api = DurableAssistants::Clio
  URL = Api::API
  READ = McpServer::Google::READ
  WRITE = McpServer::Google::WRITE
  # What other people wrote is theirs: data to read, never instructions.
  DATA = McpServer::Google::DATA
  EVERY_TIME = %w[ create_calendar_entry ].freeze

  # Clio answers only an id and an etag unless asked for more.
  FIELDS = {
    matter: "id,display_number,description,status,open_date,close_date,practice_area{id,name},client{id,name},responsible_attorney{id,name},updated_at",
    contact: "id,name,type,title,company{id,name},primary_email_address,primary_phone_number,updated_at",
    custom_field: "id,name,parent_type,field_type,displayed,required,picklist_options{id,option}",
    document: "id,name,content_type,size,created_at,updated_at,matter{id,display_number},parent{id,name}",
    calendar: "id,name,type,permission,visible",
    calendar_entry: "id,summary,description,location,start_at,end_at,all_day,calendar_owner{id,name},matter{id,display_number}"
  }.then do |fields|
    values = "custom_field_values{id,field_name,value}"
    fields.merge(matter_detail: "#{fields[:matter]},#{values}",
      contact_detail: "#{fields[:contact]},email_addresses{name,address,primary},phone_numbers{name,number,primary}," \
        "addresses{name,street,city,province,postal_code,country,primary},#{values}")
  end.freeze

  def self.string(description, **keywords) = { "type" => "string", "description" => description, **keywords.stringify_keys }
  def self.id(description) = { "type" => "integer", "minimum" => 1, "description" => description }
  def self.schema(required = [], **properties) = { "type" => "object", "properties" => properties.stringify_keys, "required" => required }
  private_class_method :string, :id, :schema

  PAGE = {
    limit: { "type" => "integer", "minimum" => 1, "maximum" => 200, "description" => "How many; 25 when left out." },
    page_token: string("next_page_token from the last page, with the same filters.", maxLength: 500)
  }.freeze
  TIME = "An ISO 8601 time, as 2026-12-01T09:00:00-05:00."

  TOOLS = [
    [ "search_matters", READ, "Find matters by words in their number or description, newest first by id: each one's id, number, " \
      "client, status and responsible attorney." + DATA,
      schema(query: string("Words to find.", maxLength: 500), status: string("Only these.", enum: %w[ open pending closed ]),
        client_id: id("Only this client's, a contact_id."), **PAGE) ],
    [ "get_matter", READ, "One matter in full, with its custom field values." + DATA, schema([ "matter_id" ], matter_id: id("From search_matters.")) ],
    [ "search_contacts", READ, "Find people and companies by name, email or phone: each one's id, type, email and phone." + DATA,
      schema(query: string("Words to find.", maxLength: 500), type: string("Only these.", enum: %w[ Person Company ]), **PAGE) ],
    [ "get_contact", READ, "One contact in full: addresses, emails, phones and custom field values." + DATA,
      schema([ "contact_id" ], contact_id: id("From search_contacts.")) ],
    [ "list_custom_fields", READ, "The account's custom fields, for reading a matter's or contact's values.",
      schema(parent_type: string("Only a matter's or a contact's.", enum: %w[ Matter Contact ]), **PAGE) ],
    [ "search_documents", READ, "Find documents by name, on one matter or across the account: each one's id, name, type, size and matter." + DATA,
      schema(query: string("Words in the name.", maxLength: 500), matter_id: id("Only this matter's."), **PAGE) ],
    [ "get_document", READ, "One document's details: name, type, size, matter and folder. Its contents are not read here." + DATA,
      schema([ "document_id" ], document_id: id("From search_documents.")) ],
    [ "list_calendars", READ, "The calendars the account can see, with each one's id and whether it may be written to.", schema ],
    [ "list_calendar_entries", READ, "Calendar entries between two times, each repeat as its own entry." + DATA,
      schema(%w[ from to ], from: string("From this time. #{TIME}", maxLength: 40), to: string("Until this time. #{TIME}", maxLength: 40),
        calendar_id: id("Only this calendar's, from list_calendars."), matter_id: id("Only this matter's."),
        query: string("Words to find.", maxLength: 500), **PAGE) ],
    [ "create_calendar_entry", WRITE, "Add an entry to a Clio calendar. It asks the person every time.",
      schema(%w[ calendar_id summary start_at end_at ], calendar_id: id("The calendar, from list_calendars."),
        summary: string("Its title.", minLength: 1, maxLength: 255), start_at: string("When it starts. #{TIME}", maxLength: 40),
        end_at: string("When it ends. #{TIME}", maxLength: 40), all_day: { "type" => "boolean", "description" => "A whole-day entry." },
        description: string("Notes.", maxLength: 8_000), location: string("Where.", maxLength: 1_000), matter_id: id("The matter it is for.")) ]
  ].map { |name, annotations, description, input|
    { "name" => name, "description" => description, "input_schema" => input, "annotations" => annotations, "asks_every_time" => EVERY_TIME.include?(name) }
  }.freeze

  def self.clio?(url) = url.to_s == URL

  def initialize(server)
    @server = server
  end

  # Starts a sign-in: the address of Clio's page that lets the app in, with a
  # state only this connector holds, used once (Connectors::CallbacksController).
  def sign_in_url
    client_id = client["client_id"]
    state = SecureRandom.urlsafe_base64(32)
    @server.update!(oauth_tokens: nil, oauth_state: state, oauth_pending: { "created_at" => Time.current.to_i })
    Api.authorize_url(client_id: client_id, redirect_uri: McpServer.redirect_uri, state: state)
  end

  # Clio's redirect back: its code exchanged for the tokens, which are kept.
  # Of two callbacks with one state, only the first goes on.
  def finish_sign_in(params)
    state = params["state"].to_s
    created_at = authorization.pending_authorization(state)&.dig("created_at")
    cleared = @server.workspace.mcp_servers.where(id: @server.id, oauth_state: state).update_all(oauth_state: nil, oauth_pending: nil) if state.present?
    @server.reload
    raise McpServer::Unreachable, "That sign-in was already used. Start again." unless cleared == 1
    unless created_at.is_a?(Integer) && (Time.current.to_i - created_at).between?(0, MCP::Client::OAuth::Provider::DEFAULT_PENDING_AUTHORIZATION_MAX_AGE)
      raise McpServer::Unreachable, "That sign-in expired. Start again."
    end
    raise McpServer::Unreachable, "Clio did not let #{@server} in (#{params["error"].to_s.first(100)})." if params["error"].present?
    raise McpServer::Unreachable, "Clio sent no code. Start again." if params["code"].blank?
    tokens = Api.exchange(client, code: params["code"].to_s, redirect_uri: McpServer.redirect_uri)
    authorization.save_tokens(tokens.slice("access_token", "refresh_token", "token_type", "expires_in"))
  rescue Api::Error => problem
    raise McpServer::Unreachable, "Could not sign in to #{@server}: #{problem.message}"
  end

  # One tool call, answered as an MCP server would: structured content, or an error the model reads.
  def call_tool(name, arguments)
    raise McpServer::SignInNeeded, "#{@server} needs you to sign in." unless @server.signed_in?
    args = arguments.to_h.stringify_keys
    content = with_token { |token| run(token, name, args) }
    { "structuredContent" => content.as_json, "content" => [ { "type" => "text", "text" => content.to_json } ] }
  rescue Api::GrantRefused
    raise McpServer::SignInNeeded, "#{@server} needs you to sign in again."
  rescue Api::Error => problem
    { "isError" => true, "content" => [ { "type" => "text", "text" => problem.message } ] }
  end

  private
    def run(token, name, args)
      case name
      when "search_matters" then page(token, "matters", :matter, args, query: args["query"], status: args["status"], client_id: args["client_id"])
      when "get_matter" then { matter: one(token, "matters/#{id!(args, "matter_id")}", :matter_detail) }
      when "search_contacts" then page(token, "contacts", :contact, args, query: args["query"], type: args["type"])
      when "get_contact" then { contact: one(token, "contacts/#{id!(args, "contact_id")}", :contact_detail) }
      when "list_custom_fields" then page(token, "custom_fields", :custom_field, args, parent_type: args["parent_type"])
      when "search_documents" then page(token, "documents", :document, args, query: args["query"], matter_id: args["matter_id"])
      when "get_document" then { document: one(token, "documents/#{id!(args, "document_id")}", :document) }
      when "list_calendars" then page(token, "calendars", :calendar, args)
      when "list_calendar_entries"
        page(token, "calendar_entries", :calendar_entry, args, from: args["from"], to: args["to"], calendar_id: args["calendar_id"],
          matter_id: args["matter_id"], query: args["query"], expanded: "true")
      when "create_calendar_entry" then { calendar_entry: create_calendar_entry(token, args) }
      else raise Api::Error, "#{@server} has no tool #{name}."
      end
    end

    # One page, in id order, which Clio's cursor paging needs, and the token for the next.
    def page(token, path, fields, args, **filters)
      query = { fields: FIELDS[fields], order: "id(asc)", limit: (args["limit"] || 25).to_i.clamp(1, 200), page_token: args["page_token"].presence }
      answer = Api.request(token, :get, path, query: query.merge(filters).compact_blank)
      { path.split("/").last.to_sym => Array(answer["data"]), next_page_token: Api.next_page_token(answer) }.compact
    end

    def one(token, path, fields) = Api.request(token, :get, path, query: { fields: FIELDS[fields] })["data"]

    def id!(args, key) = Integer(args[key].to_s, exception: false)&.then { it.positive? ? it : nil } || raise(Api::Error, "#{key} must be a number.")

    def create_calendar_entry(token, args)
      entry = args.slice("summary", "start_at", "end_at", "all_day", "description", "location")
        .merge("calendar_owner" => { "id" => id!(args, "calendar_id") }, "matter" => (args["matter_id"].present? ? { "id" => id!(args, "matter_id") } : nil)).compact
      Api.request(token, :post, "calendar_entries", query: { fields: FIELDS[:calendar_entry] }, body: { data: entry })["data"]
    end

    # The app's client ID and secret, read from the vault for this one use.
    def client = McpServer::VaultClient.new(@server).to_h.slice("client_id", "client_secret")

    def authorization = McpServer::Authorization.new(@server)

    # The access token, renewed first when it is about to expire, and once more
    # if Clio turns it away.
    def with_token
      renew if expiring?
      yield @server.oauth_tokens["access_token"]
    rescue Api::GrantRefused
      raise
    rescue Api::Unauthorized
      raise Api::Error, "Clio turned away a token it had just renewed, so nothing was done. Try again." if @renewed
      renew
      begin
        yield @server.oauth_tokens["access_token"]
      rescue Api::Unauthorized
        raise Api::Error, "Clio turned away a token it had just renewed, so nothing was done. Try again."
      end
    end

    def expiring?
      expires_at = @server.oauth_tokens["expires_at"]
      @server.oauth_tokens["access_token"].blank? || (expires_at.present? && Time.zone.at(expires_at) < McpServer::RENEW_BEFORE.from_now)
    end

    # Logs what Clio answered (its status and error code), never a token or the secret.
    def renew
      @renewed = true
      refresh_token = @server.oauth_tokens["refresh_token"] or raise Api::GrantRefused, "Clio gave no refresh token at sign-in"
      fresh = Api.refresh(client, refresh_token)
      authorization.save_tokens(@server.oauth_tokens.merge(fresh.slice("access_token", "refresh_token", "token_type", "expires_in").compact_blank))
      Rails.logger.info "Clio connector #{@server.id} renewed its token"
    rescue Api::Error => problem
      Rails.logger.warn "Clio connector #{@server.id} could not renew: #{problem.message}"
      raise
    end
end
