class Agent::ReportingInstructions
  def initialize(agent)
    @agent = agent
  end

  def to_s
    manager = @agent.manager
    reports = @agent.reports.order(:name, :id).to_a
    return "" unless manager || reports.any?

    lines = [ ("Manager: #{peer(manager)}" if manager), *reports.map { |report| "Direct report: #{peer(report)}#{first_turn_id(report)}" } ]
    <<~PROMPT

      ## Reporting lines
      #{lines.compact.join("\n")}

      Assign work only to your direct reports when acting as their manager. On a task you were given, send results or blockers back on that same task with concourse_reply; answer an unrelated requester on their own task too.
      For a new internal reporting update with no task, contact your direct manager, or, with no manager, answer the requester or ask a person. Pass a summary up, not the whole thread.
      For new reporting messages, use concourse_send with the explicit peer and network listed here. If there is no clear Concourse route, tell the person. Do not fall back to a bridge, another workspace, or another channel. This is a reporting default, not a restriction on unrelated peer work.
      Reporting grants no authority to answer approval cards and no access to anyone else's threads, tools, files, or credentials.
      #{"For your approved local report’s first turn, if brief_report is available, use it with the exact agent ID and the message to pass on, as yourself." if reports.any?(&:workspace_setup) && @agent.tool_names.include?("brief_report")}
      #{"For outward correspondence without direct Concourse membership, ask a person to hand the request to your manager. The manager decides and sends under their own identity, using their usual approvals. Never ask for their credentials or send as them." if @agent.workspace_setup && @agent.concourse_agents.empty?}

    PROMPT
  end

  private
    def first_turn_id(report)
      " — local report ID #{report.id}" if @agent.tool_names.include?("brief_report") && report.workspace_setup&.manager_id == @agent.id
    end

    def peer(other)
      identity = route_to(other)
      "#{other.name.squish} — #{identity ? "peer #{identity.handle}, network #{identity.organization}" : "no clear Concourse route"}"
    end

    def route_to(other)
      home = @agent.workspace.concourse_home
      ours = identities(@agent, home)
      theirs = identities(other, home)
      shared = theirs.select { |identity| ours.any? { it.organization == identity.organization } }
      shared.sole if shared.one?
    end

    def identities(agent, home)
      identities = agent.concourse_agents.admitted
      home ? identities.where(organization: home).select(&:speaks?) : identities.select(&:connected?)
    end
end
