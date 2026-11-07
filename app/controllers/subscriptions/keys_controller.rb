# The owner's pasted API key for a provider (ApiKey): update saves it, once
# the sidecar has checked it with the provider; destroy removes it. The key
# goes straight to the sidecar and is neither stored nor logged here
# (api_key is a filtered parameter).
class Subscriptions::KeysController < ApplicationController
  include SubscriptionConsole

  before_action :set_api_key

  def update
    key = params.expect(api_key: %i[ version key ])
    @api_key.update(key: key[:key], version: key[:version])
    redirect_to subscriptions_path, notice: "Saved. Assistants on a #{@api_key.name} model use it from their next message.", status: :see_other
  end

  def destroy
    @api_key.destroy(params.expect(:version))
    redirect_to subscriptions_path, notice: "Removed. Assistants on a #{@api_key.name} model can't reach #{@api_key.service} until a key is saved again.", status: :see_other
  end

  private
    def set_api_key
      @api_key = ApiKey.find(params[:subscription_provider])
    end
end
