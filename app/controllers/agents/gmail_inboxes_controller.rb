module Agents
  class GmailInboxesController < ApplicationController
    include AgentSettings

    before_action do
      head :not_found unless Agent::GmailInbox.owner_at_sign_in?(@agent, Current.user, session[:email])
    end

    def update
      fields = params.expect(gmail_inbox: %i[ enabled mcp_server_id mailbox ])
      @gmail_inbox = @agent.gmail_inbox || @agent.build_gmail_inbox
      if fields[:enabled] != "1"
        @gmail_inbox.with_lock { @gmail_inbox.pause! } if @gmail_inbox.persisted?
        return saved agent_channels_path(@agent)
      end

      if fields[:mcp_server_id].blank?
        @gmail_inbox.errors.add(:base, "Choose a Gmail connector.")
        return render_inbox_error
      end

      connector = Current.workspace.mcp_servers.find(fields[:mcp_server_id])
      raise ActiveRecord::RecordNotFound unless Agent::GmailInbox.supports?(connector)
      @gmail_inbox.mcp_server = connector unless @gmail_inbox.persisted?
      @requested_mailbox = fields[:mailbox]
      if @gmail_inbox.activate(connector: connector, by: Current.user, verified_email: session[:email], mailbox: @requested_mailbox)
        saved agent_channels_path(@agent)
      else
        render_inbox_error
      end
    end

    private
      def render_inbox_error = render "agents/channels/show", status: :unprocessable_entity
  end
end
