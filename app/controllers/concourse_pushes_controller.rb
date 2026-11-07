# Concourse rings here when one of an agent's events is new (its push
# webhook, registered by ConcourseAgent#register_push). The notice carries no
# mail, only the event's number; the token in its header admits it, compared
# in constant time. It wakes a read of the agent's event log, which is the
# record: a repeat, or one out of order, finds nothing new there, and a lost
# one loses nothing. Answers at once, before the read.
class ConcoursePushesController < ActionController::API
  # Concourse retries a 429 later; a wrong token is final. It posts from one
  # address for every agent, so the address gets more room than an agent.
  rate_limit to: 600, within: 1.minute, name: "address"
  rate_limit to: 60, within: 1.minute, by: -> { params[:id].to_s }, name: "agent"

  def create
    concourse_agent = ConcourseAgent.find_by(id: params[:id]) # tenancy-ok: the token below, given to this one agent, admits it
    token = request.headers["X-A2A-Notification-Token"].to_s
    return head :unauthorized unless concourse_agent&.push_token.present? &&
      ActiveSupport::SecurityUtils.secure_compare(concourse_agent.push_token, token)
    # Discarded while one is reading already.
    ConcourseListenJob.perform_later(concourse_agent)
    head :no_content
  end
end
