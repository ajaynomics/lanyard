# One sign-in to a subscription: start makes a fresh, one-use link; update
# completes it with what the owner pastes back (Claude's code, or the address
# ChatGPT's sign-in ends on). Neither the link nor the paste is stored or
# logged here.
class Subscriptions::LoginsController < ApplicationController
  include SubscriptionConsole

  before_action :set_subscription

  def create
    started = @subscription.start(params.expect(:version))
    @subscriptions = Subscription.all.map { it.provider == started.provider ? started : it }
    render "subscriptions/index"
  end

  def update
    login = params.expect(login: %i[ version id code ])
    @subscription.finish(version: login[:version], id: login[:id], code: login[:code])
    redirect_to subscriptions_path, notice: "Connected. The bots use this #{@subscription.name} from their next message.", status: :see_other
  end

  private
    def set_subscription
      @subscription = Subscription.find(params[:subscription_provider])
    end
end
