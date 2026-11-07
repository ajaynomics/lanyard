# The person's connectors, which all their agents use, and the one form that
# adds a connector at either level: all agents, or only one
# (connector[conversation_id]), as pi's user and project mcp.json. A
# connector can be filled in field by field or pasted as pi's own entry
# (connector[json]). Every change applies from each agent's next turn.
class ConnectorsController < ApplicationController
  include ConnectorPages

  def index
    @connectors = Current.user.mcp_servers.global
  end

  def create
    connectors = new_connectors
    if (invalid = connectors.find(&:invalid?))
      return redirect_to connector_page(invalid), alert: "#{invalid.name}: #{invalid.errors.full_messages.to_sentence}"
    end
    McpServer.transaction { connectors.each(&:save!) }
    added(connectors)
  rescue McpServer::Entry::Invalid, ActiveRecord::RecordInvalid => problem
    redirect_to conversation ? conversation_connectors_path(conversation) : connectors_path, alert: problem.message
  end

  # pi's `enabled`: a connector switched off keeps its sign-in and settings.
  def update
    connector = Current.user.mcp_servers.find(params[:id])
    connector.update!(params.expect(connector: %i[ enabled ]))
    redirect_to connector_page(connector), notice: "#{connector} is #{connector.enabled? ? 'on' : 'off'} from the next message."
  end

  def destroy
    connector = Current.user.mcp_servers.find(params[:id])
    connector.destroy!
    notice = connector.url ? "Removed #{connector}. Its tools go from the next message." : "Switched #{connector} back on for this agent."
    redirect_to connector_page(connector), notice: notice
  end

  private
    def new_connectors
      fields = params.expect(connector: %i[ name url token client_id client_secret enabled json conversation_id ])
      entries = fields[:json].present? ? McpServer::Entry.parse(fields[:json]).values : [ fields.except(:json, :conversation_id) ]
      entries.map { Current.user.mcp_servers.new(it.merge(conversation: conversation)) }
    end

    def conversation
      id = params.dig(:connector, :conversation_id)
      @conversation ||= Current.user.conversations.find(id) if id.present?
    end

    # One that asks for a sign-in goes straight to it; the rest list their tools.
    def added(connectors)
      first = connectors.first
      if connectors.one? && !first.enabled? && first.url.nil?
        redirect_to connector_page(first), notice: "Switched #{first} off for this agent."
      elsif connectors.one? && first.enabled? && !first.authorized_by_header?
        sign_in_to first
      else
        connectors.select(&:enabled?).each { McpServerRefreshJob.perform_later(it) }
        redirect_to connector_page(first), notice: "Added #{connectors.map(&:name).to_sentence}. Listing their tools; sign in where asked."
      end
    end
end
