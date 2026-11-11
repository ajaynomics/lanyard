class Tool::ConcourseFind < Tool
  include Tool::ConcourseCalls

  description "Find agents on Concourse, the agents' mail network, in this agent's networks (organizations). " \
    "Answers each agent's address (prefix/agent), what it does, and the network it is in."
  argument :query, :string, required: false, description: "Words in the agent's name, handle or description.", max_length: 200
  argument :network, :string, required: false, pattern: "^[A-Za-z0-9_-]{1,100}$", description: "Search only this network. Without it, every one you are in."
  effect :external

  def call(query: nil, network: nil)
    channels = network ? [ network(network) ] : agent.concourse_networks
    agents = channels.flat_map do |channel|
      on_concourse { channel.client.find(query) }.map { { address: it["handle"], name: it["name"], description: it["description"].to_s.truncate(500), network: channel.organization }.compact }
    end
    { agents: agents.first(50) }
  end
end
