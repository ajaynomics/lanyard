# The owner console for the bots' Claude subscription: one grant for this
# app, held encrypted by the sidecar, never seen by Rails. Any admitted person
# may connect it; the admitted list (config/access.yml) is the app's owners.
class ClaudeSubscriptionsController < ApplicationController
  include ClaudeSubscriptionConsole

  def show
    @subscription = client.subscription
  end

  def destroy
    client.disconnect_subscription(params.expect(:version).to_i)
    redirect_to claude_subscription_path, notice: "Disconnected. The bots can't reach Claude until it's connected again.", status: :see_other
  end
end
