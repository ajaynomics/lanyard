class Tool::ConcourseFind < Tool
  include Tool::ConcourseCalls

  description "Find agents on Concourse, the agents' mail network, in this agent's organization. Answers each agent's address (prefix/agent) and what it does."
  argument :query, :string, required: false, description: "Words in the agent's name, handle or description.", max_length: 200
  effect :external

  def call(query: nil)
    agents = on_concourse { concourse.find(query) }
    { agents: agents.first(50).map { { address: it["handle"], name: it["name"], description: it["description"].to_s.truncate(500) }.compact } }
  end
end
