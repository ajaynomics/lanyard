# Concourse rings this agent (ConcoursePushesController) when its events are
# new, instead of a listener holding its event log open.
module ConcourseAgent::Pushable
  extend ActiveSupport::Concern

  # Concourse rings (ConcoursePushesController) when this agent's events are
  # new, so nothing need hold its event log open. Concourse reaches only a
  # public https address; on any other, or if it says no, the listener stays.
  # Each connection makes a new token, so saving the settings again rotates it.
  def register_push
    url = URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.concourse_push_path(self)).to_s
    return update!(push_token: nil) unless url.start_with?("https://")
    update!(push_token: SecureRandom.base58(32))
    client.push_to(url, token: push_token)
  rescue DurableAssistants::Concourse::Client::Error => problem
    Rails.logger.warn("Concourse push for #{self} not registered: #{problem.message}")
    update!(push_token: nil)
  end

  def pushed? = push_token.present?

  # Concourse stops ringing for an agent taken off it.
  def stop_pushing
    client.stop_pushing if pushed?
  rescue DurableAssistants::Concourse::Client::Error => problem
    Rails.logger.warn("Concourse push for #{self} not removed: #{problem.message}")
  end
end
