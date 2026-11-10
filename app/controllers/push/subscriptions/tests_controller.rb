# "Send test notification" in Settings: one notice to this device, through
# the same sender as every other, sent now rather than queued so the page can
# say what the push service answered.
class Push::Subscriptions::TestsController < ApplicationController
  NOTICE = { kind: "test", title: "Test notification", body: "Notifications work on this device.", tag: "test" }.freeze

  def create
    subscription = Current.user.push_subscriptions.find(params[:subscription_id])
    delivery = subscription.deliver(NOTICE.merge(url: settings_account_path, badge: Current.user.agents_needing_you))
    render json: { outcome: delivery.outcome, message: message(delivery) }
  end

  private
    def message(delivery)
      case delivery.outcome
      when :sent then "Sent. It should appear in a moment; if it doesn't, check this device's notification settings."
      when :expired then "This device's subscription had expired (#{delivery.reason}) and was removed. Turn notifications on again."
      else "Sending failed (#{delivery.reason}). Try again later; if it keeps failing, tell whoever runs this app."
      end
    end
end
