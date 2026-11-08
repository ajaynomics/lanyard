# The person's connectors, which all their conversations use, and the one form that
# adds a connector at either level: all conversations, or only one
# (connector[conversation_id]), as pi's user and project mcp.json. A
# connector can be filled in field by field or pasted as pi's own entry
# (connector[json]). Every change applies from each conversation's next turn. A
# command connector lists its tools on a conversation's computer: the conversation whose
# page it was added from (conversation_id).
class ConnectorsController < ApplicationController
  include ConnectorPages

  layout "settings", only: %i[ index show ]

  def index
    @connectors = Current.user.mcp_servers.global
  end

  # One of the person's connectors: where it stands, and its tools, each
  # with a switch for every agent.
  def show
    @connector = Current.user.mcp_servers.global.find(params[:id])
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
  def update
    connector = Current.user.mcp_servers.find(params[:id])
    changes = params.expect(connector: %i[ enabled loaded ])
    return redirect_to connector_page(connector), alert: connector.errors.full_messages.to_sentence unless connector.update(changes)
    saved connector_page(connector)
  end

  def destroy
    connector = Current.user.mcp_servers.find(params[:id])
    return redirect_to(connector_page(connector), alert: "#{connector} is the install's; switch it off instead.") if connector.install
    connector.destroy!
    notice = !connector.switch_off? ? "Removed #{connector}. Its tools go from the next message." : "Switched #{connector} back on for this agent."
    redirect_to connector.conversation ? conversation_connectors_path(connector.conversation) : connectors_path, notice: notice
  end

  private
    # A gallery entry's address, scope and instance app come from the gallery, never the form.
    def new_connectors
      fields = params.expect(connector: %i[ name url token client_id client_secret enabled json conversation_id gallery ])
      entries = if fields[:json].present? then McpServer::Entry.parse(fields[:json]).values
      elsif fields[:gallery].present? then [ fields.except(:json, :conversation_id, :gallery, :url).merge(McpServer.gallery_attributes(fields[:gallery])) ]
      else [ fields.except(:json, :conversation_id, :gallery) ]
      end
      entries.map { Current.user.mcp_servers.new(it.merge(conversation: conversation)) }
    end

    def conversation
      id = params.dig(:connector, :conversation_id)
      @conversation ||= Current.user.conversations.find(id) if id.present?
    end

    # Where the form was: a connector that was not added has no page of its own.
    def added_from = conversation ? conversation_connectors_path(conversation) : connectors_path

    def from_conversation
      Current.user.conversations.find(params[:conversation_id]) if params[:conversation_id].present?
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
        page = connectors.one? || first.conversation ? connector_page(first) : connectors_path
        redirect_to page, notice: "Added #{connectors.map(&:name).to_sentence}. Listing their tools; sign in where asked."
      end
    end
end
