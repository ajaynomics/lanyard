# The phone app's notifications (Push::Device). Its Settings page asks iOS for
# permission and a device token (the notification-token bridge component) and
# posts the token here; the app's Sign out takes it away (SessionsController).
# Which of Apple's services the token is for comes from the app's own build,
# in its user agent: a header can only choose where a notice goes, never who
# gets it, which the session alone decides.
class Push::DevicesController < ApplicationController
  def create
    token = params.expect(:token).to_s.strip.downcase
    # The token belongs to the phone, not to an account: whoever signs in on it now is whom it notifies.
    Push::Device.where(token: token).where.not(user: Current.user).delete_all # tenancy-ok: one phone's token, taken over by the person now using it
    device = Current.user.push_devices.find_or_initialize_by(token: token)
    if device.update(environment: request.user_agent.to_s[/APNs\/(sandbox|production)/, 1] || "production", session_digest: Push::Device.digest(session))
      # Once per phone and person, not at each launch's repeat; never the token itself.
      Current.user.push_attempts.create!(outcome: "registered", user_agent: request.user_agent) if device.previously_new_record?
      device.reported(refused: false)
      head :created
    else
      head :unprocessable_entity
    end
  end
end
