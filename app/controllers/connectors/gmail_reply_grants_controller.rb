class Connectors::GmailReplyGrantsController < ApplicationController
  include ConnectorPages

  before_action :set_connector

  def create
    grant = @connector.with_lock do
      require_workspace_owner
      if @connector.conversation_id?
        agent = @connector.conversation.agent
        values = params.expect(gmail_reply_grant: [ :address ])
      else
        values = params.expect(gmail_reply_grant: %i[ agent_id address ])
        agent = @connector.workspace.agents.find(values[:agent_id])
      end
      @connector.gmail_reply_grants.create(agent: agent, address: values[:address]) if @connector.signed_in?
    end
    if grant.nil?
      redirect_to connector_page(@connector), alert: "Sign in to Gmail before allowing replies.", status: :see_other
    elsif grant.persisted?
      saved connector_page(@connector)
    else
      redirect_to connector_page(@connector), alert: grant.errors.full_messages.to_sentence, status: :see_other
    end
  rescue ActiveRecord::RecordNotUnique
    redirect_to connector_page(@connector), alert: "That agent already has a reply grant on this connector.", status: :see_other
  end

  def destroy
    @connector.with_lock do
      require_workspace_owner
      @connector.gmail_reply_grants.find(params[:id]).destroy!
    end
    saved connector_page(@connector)
  end

  private
    def set_connector
      @connector = find_in_workspace(:connectors, params[:connector_id])
      require_workspace_owner
    end

    def require_workspace_owner
      raise ActiveRecord::RecordNotFound unless @connector.google == :gmail && Current.user == @connector.workspace.owner
      if @connector.conversation_id? && @connector.conversation.workspace != @connector.workspace
        raise ActiveRecord::RecordNotFound
      end
    end
end
