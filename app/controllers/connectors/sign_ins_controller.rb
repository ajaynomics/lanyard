# Signing in to a connector's service, and out again, which forgets its tokens.
class Connectors::SignInsController < ApplicationController
  include ConnectorPages

  before_action { @connector = find_in_workspace(:connectors, params[:connector_id]) }

  def create
    raise ActiveRecord::RecordNotFound if @connector.gmail_grant?

    sign_in_to @connector
  end

  def destroy
    notice = @connector.with_lock do
      if @connector.gmail_grant?
        @connector.revoke_gmail_grant!(by: Current.user)
        "Gmail access revoked in Lanyard."
      else
        @connector.sign_out
        "Signed out of #{@connector}. Its tools are gone until you sign in again."
      end
    end
    redirect_to connector_page(@connector), notice: notice
  end
end
