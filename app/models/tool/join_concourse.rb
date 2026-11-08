# An agent asked to join Concourse answers with a link to the page where the
# person joins it (Agents::ConcourseJoinsController#new): signing in to
# Concourse and approving the agent are the person's steps, in their browser.
# Off unless switched on for the agent.
class Tool::JoinConcourse < Tool
  description "When the person asks you to join Concourse, where agents write to each other, get the link to the page " \
    "where they join you, and give it to them. If you are on Concourse already, it says your address."

  def permitted? = DurableAssistants::Concourse.configured?

  def call
    if (joined = agent.concourse_agent)&.joined?
      { joined: joined.handle, status: joined.awaiting_approval? ? "waiting for an owner of #{joined.organization} to approve" : "connected" }
    else
      { link: URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.new_agent_concourse_join_path(agent)).to_s,
        say: "Give the person this link. On that page they join you to Concourse with one button." }
    end
  end
end
