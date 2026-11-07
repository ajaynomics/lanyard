# Campfire posts here each message for an agent's bot (CampfireBot). The token
# in the path admits it, not a header or address; it answers at once, with no
# body, so Campfire posts nothing back, and the agent hears it from a job.
class CampfireWebhooksController < ActionController::API
  wrap_parameters false
  # Campfire posts from one address for every bot, so the address gets more room than a token.
  rate_limit to: 600, within: 1.minute, name: "address"
  rate_limit to: 60, within: 1.minute, by: -> { params[:token].to_s }, name: "token"

  def create
    bot = CampfireBot.find_by(token: params[:token].to_s) # tenancy-ok: the secret token names the one agent it was given to
    return head :not_found unless bot && CampfireBot.configured?
    payload = request.request_parameters.slice("room", "user", "message")
    CampfireReceiveJob.perform_later(bot, payload.to_h)
    head :no_content
  end
end
