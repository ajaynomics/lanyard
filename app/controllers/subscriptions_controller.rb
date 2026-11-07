# The owner console for the agents' subscriptions: Claude's and ChatGPT's, one
# grant each for this app, held encrypted by the sidecar, never seen by Rails;
# and beside them the Claude API key (Subscriptions::KeysController).
# Any admitted person may connect them; the admitted list (config/access.yml)
# is the app's owners.
class SubscriptionsController < ApplicationController
  include SubscriptionConsole

  def index
    @subscriptions = Subscription.all
    @api_keys = ApiKey.all
  end

  def destroy
    subscription = Subscription.find(params[:provider])
    subscription.disconnect(params.expect(:version))
    redirect_to subscriptions_path, notice: "Disconnected. The agents can't reach #{subscription.service} until it's connected again.", status: :see_other
  end
end
