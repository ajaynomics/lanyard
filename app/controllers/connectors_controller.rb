# The workspace's connectors, which all its conversations use, and the one form that
# adds a connector at either level: all conversations, or only one
# (connector[conversation_id]), as pi's user and project mcp.json. A
# connector can be filled in field by field or pasted as pi's own entry
# (connector[json]). Every change applies from each conversation's next turn. A
# command connector lists its tools on a conversation's computer: the conversation whose
# page it was added from (conversation_id).
class ConnectorsController < ApplicationController
  include ConnectorPages, WorkspaceScoped

  layout "settings", only: %i[ index show ]

  def index
    @connectors = Current.workspace.mcp_servers.global
  end

  # One of the workspace's connectors: where it stands, and its tools, each
  # with a switch for every agent. In whichever of the person's workspaces it is.
  def show
    @connector = find_in_workspace(:connectors, params[:id])
    raise ActiveRecord::RecordNotFound, "#{@connector} is one agent's" if @connector.conversation_id
  end

  def create
    connectors = new_connectors
    if (invalid = connectors.find(&:invalid?))
      return redirect_to added_from, alert: "#{invalid.name}: #{invalid.errors.full_messages.to_sentence}"
    end
    McpServer.transaction { connectors.each(&:save!) }
    connectors.each { ahoy.track "Connector added", connector_id: it.id, agent_id: it.conversation&.agent_id }
    added(connectors)
  rescue McpServer::Entry::Invalid, ActiveRecord::RecordInvalid => problem
    redirect_to added_from, alert: problem.message
  end

  # pi's `enabled`: a connector switched off keeps its sign-in and settings.
  # asks_every_write: each of its writes asks every time (docs/connectors.md).
  def update
    connector = find_in_workspace(:connectors, params[:id])
    changes = params.expect(connector: %i[ enabled loaded asks_every_write ])
    # A person's connector is core or lookup for each agent, on its Tools (Agents::CoreConnectorsController).
    changes = changes.except(:loaded) if connector.conversation_id.nil?
    return redirect_to connector_page(connector), alert: "Only #{Current.workspace.owner} or the install's owner turns #{connector} on." if turning_on_an_office_connector?(connector, changes)
    updated = connector.with_lock do
      raise ActiveRecord::RecordNotFound if connector.gmail_grant?
      connector.update(changes)
    end
    return redirect_to connector_page(connector), alert: connector.errors.full_messages.to_sentence unless updated
    saved connector_page(connector)
  end

  def destroy
    connector = find_in_workspace(:connectors, params[:id])
    return redirect_to(connector_page(connector), alert: "#{connector} is the install's; switch it off instead.") if connector.install
    connector.with_lock do
      if connector.gmail_grant?
        raise ActiveRecord::RecordNotFound unless connector.gmail_grant_owner?(Current.user) && connector.gmail_grant["revoked_at"]
      end
      connector.destroy!
    end
    notice = !connector.switch_off? ? "Removed #{connector}. Its tools go from the next message." : "Switched #{connector} back on for this agent."
    redirect_to connector.conversation ? conversation_connectors_path(connector.conversation) : workspace_connectors_path(Current.workspace), notice: notice
  end

  private
    # One of the install's connectors is on in a workspace only by its owner's choice, or the install's owner's (#168).
    def turning_on_an_office_connector?(connector, changes)
      connector.install && !connector.conversation_id && !connector.enabled? &&
        ActiveModel::Type::Boolean.new.cast(changes[:enabled]) && !Current.workspace.turns_on_install_connectors?(Current.user)
    end

    # A gallery entry's address, scope and instance app come from the gallery, never the form.
    def new_connectors
      fields = params.expect(connector: %i[ name url token client_id client_secret vault_entry enabled json conversation_id gallery host port username ] + McpServer::X::KEYS.map(&:to_sym))
      mailbox = fields.extract!(:host, :port, :username).to_h.symbolize_keys
      x = fields.extract!(*McpServer::X::KEYS)
      fields[:token] = McpServer::X.token(x) if x.values.any?(&:present?)
      entries = if fields[:json].present? then McpServer::Entry.parse(fields[:json]).values
      elsif fields[:gallery].present? then [ fields.except(:json, :conversation_id, :gallery, :url).merge(McpServer.gallery_attributes(fields[:gallery], **mailbox)) ]
      else [ fields.except(:json, :conversation_id, :gallery) ]
      end
      entries.map { Current.workspace.mcp_servers.new(it.merge(user: Current.user, conversation: conversation)) }
    end

    def conversation
      id = params.dig(:connector, :conversation_id)
      @conversation ||= Current.workspace.conversations.find(id) if id.present?
    end

    # Where the form was: a connector that was not added has no page of its own.
    def added_from = conversation ? conversation_connectors_path(conversation) : workspace_connectors_path(Current.workspace)

    def from_conversation
      Current.workspace.conversations.find(params[:conversation_id]) if params[:conversation_id].present?
    end

    # One that asks for a sign-in goes straight to it; the rest list their tools.
    def added(connectors)
      first = connectors.first
      if connectors.one? && !first.enabled? && first.switch_off?
        redirect_to connector_page(first), notice: "Switched #{first} off for this agent."
      elsif connectors.one? && first.enabled? && !first.command? && !first.authorized_by_header?
        sign_in_to first
      else
        connectors.select(&:enabled?).each { McpServerRefreshJob.perform_later(it, it.conversation || from_conversation) }
        page = connectors.one? || first.conversation ? connector_page(first) : workspace_connectors_path(Current.workspace)
        redirect_to page, notice: "Added #{connectors.map(&:name).to_sentence}. Listing their tools; sign in where asked."
      end
    end
end
