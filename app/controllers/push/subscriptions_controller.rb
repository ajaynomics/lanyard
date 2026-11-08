# Notifications on this browser, turned on and off from Settings (You). The
# page's script asks the browser's push service for an address and posts it
# here; turning them off, or Remove beside any of the person's devices,
# deletes it.
class Push::SubscriptionsController < ApplicationController
  def create
    raise ActionController::RoutingError, "Not Found" unless Push.configured?
    fields = params.expect(push_subscription: %i[ endpoint p256dh_key auth_key ])
    # The address belongs to the browser, not to an account: whoever turns
    # notifications on in it now is whom it notifies, and nobody before them.
    Push::Subscription.where(endpoint: fields[:endpoint]).where.not(user: Current.user).delete_all # tenancy-ok: one browser's address, taken over by the person now using it
    subscription = Current.user.push_subscriptions.find_or_initialize_by(endpoint: fields[:endpoint])
    if subscription.update(fields.merge(user_agent: request.user_agent))
      head :created
    else
      head :unprocessable_entity
    end
  end

  def destroy
    Current.user.push_subscriptions.find(params[:id]).destroy
    respond_to do |format|
      format.html { saved(settings_account_path) }
      format.json { head :no_content }
    end
  end
end
