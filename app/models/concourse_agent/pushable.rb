# Concourse rings this agent (ConcoursePushesController) when its events are
# new, instead of a listener holding its event log open.
module ConcourseAgent::Pushable
  extend ActiveSupport::Concern

  # Concourse rings (ConcoursePushesController) when this agent's events are
  # new, so nothing need hold its event log open. Concourse reaches only a
  # public https address; on any other, or if it says no, the listener stays.
  # Each registration makes a new token; one is made when the agent is admitted.
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

  # Concourse stops ringing for an agent being taken off it. Asked before it
  # is retired, while its token still works; if the retiring then fails, the
  # minute's sweep starts a listener for it instead.
  def stop_pushing
    return unless pushed?
    client.stop_pushing
    update!(push_token: nil)
  rescue DurableAssistants::Concourse::Client::Error => problem
    Rails.logger.warn("Concourse push for #{self} not removed: #{problem.message}")
  end
end
