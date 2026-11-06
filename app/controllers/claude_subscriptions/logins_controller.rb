# One sign-in to the Claude subscription: start makes a fresh, one-use link;
# update completes it with the code Anthropic shows. Neither the link nor the
# code is stored or logged here.
class ClaudeSubscriptions::LoginsController < ApplicationController
  include ClaudeSubscriptionConsole

  def create
    @subscription = client.start_subscription(params.expect(:version).to_i)
    render "claude_subscriptions/show"
  end

  def update
    login = params.expect(login: %i[ version id code ])
    client.finish_subscription(login[:version].to_i, login[:id].to_s, login[:code].to_s)
    redirect_to claude_subscription_path, notice: "Connected. The bots use this Claude subscription from their next message.", status: :see_other
  end
end
