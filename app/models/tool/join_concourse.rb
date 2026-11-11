# An agent asked to join Concourse answers with a link to the page where the
# person joins it (Agents::ConcourseJoinsController#new): signing in to
# Concourse and approving the agent are the person's steps, in their browser.
# Off unless switched on for the agent.
class Tool::JoinConcourse < Tool
  description "When the person asks you to join Concourse, where agents write to each other, or another network on it, get the link to the page " \
    "where they join you, and give it to them. It also says the networks you are in already."

  def permitted? = DurableAssistants::Concourse.configured?

  def call
    joined = agent.concourse_agents.select(&:joined?).map do
      { network: it.organization, address: it.handle, status: it.awaiting_approval? ? "waiting for an owner of #{it.organization} to approve" : "connected" }
    end
    { joined: joined.presence,
      link: URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.new_agent_concourse_join_path(agent)).to_s,
      say: "Give the person this link. On that page they join you to #{joined.any? ? "another network on " : ""}Concourse with one button." }.compact
  end
end
