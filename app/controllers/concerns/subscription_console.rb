# What the subscription console's pages share: they carry a one-use sign-in
# link, so nothing caches them or sends them to another site as a referrer
# (same-origin, not no-referrer: a browser then sends `Origin: null` with the
# page's own forms, which Rails' forgery check refuses), and the sidecar's
# refusals become a sentence and a fresh start.
module SubscriptionConsole
  extend ActiveSupport::Concern

  REFUSALS = {
    "subscription_changed" => "The connection changed in another tab. Start again from here.",
    "invalid_or_expired_oauth_completion" => "That doesn't match this sign-in, or the sign-in expired. Start a new one.",
    "oauth_outcome_unconfirmed" => "The sign-in wasn't confirmed. Start a new one; the old one can't be used again.",
    "subscription_not_configured" => "This server isn't set up for that subscription."
  }.freeze

  included do
    before_action { response.set_header("Cache-Control", "no-store") }
    before_action { response.set_header("Referrer-Policy", "same-origin") }
    rescue_from DurableAssistants::PiDurable::Client::Error do |error|
      raise error unless REFUSALS.key?(error.category)
      redirect_to subscriptions_path, alert: REFUSALS.fetch(error.category), status: :see_other
    end
  end
end
