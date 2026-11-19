# An identity outside its workspace's home network is a bridge
# (docs/design/workspaces.md, 2.3 and 3): it reads mail and sends only once
# the workspace's owner has approved it, and who approved it, and when, is
# kept and logged. One its owner joins is approved as it is made. Where the
# workspace names no home network every join is ordinary, as before.
#
# Each network stays its own: a task is answered on the network it came on
# (Tool::ConcourseCalls), and a send onto a bridge asks a person every time
# (Tool::ConcourseSend), so nothing from one network reaches another without
# a person allowing that one message, recorded in the ledger.
module ConcourseAgent::Bridge
  extend ActiveSupport::Concern

  included do
    belongs_to :bridge_approved_by, class_name: "User", optional: true
  end

  def bridge? = agent.workspace.concourse_home.present? && organization != agent.workspace.concourse_home

  def waiting_for_owner? = bridge? && bridge_approved_at.nil?

  # Admitted by Concourse and, a bridge, approved here.
  def speaks? = admitted? && !waiting_for_owner?

  def approve_bridge(person)
    update!(bridge_approved_by: person, bridge_approved_at: Time.current)
    Rails.logger.info "Concourse bridge #{id} of agent #{agent_id} to #{organization} approved by user #{person.id}"
  end

  # Its agent moved to another workspace: judged anew against that one's
  # home network, as if just joined by whoever moved it.
  def approve_again(mover)
    update!(bridge_approved_by: nil, bridge_approved_at: nil)
    approve_or_ask(mover)
  end

  # Just joined: a bridge its workspace's owner made is approved by them;
  # one a member made waits, and the owner is told.
  def approve_or_ask(joiner)
    return unless waiting_for_owner?
    owner = agent.workspace.owner
    return approve_bridge(joiner) if joiner == owner
    Push.deliver owner, kind: "needs_you", agent: agent, title: "#{agent} waits for you",
      body: "#{joiner} joined #{agent} to #{organization}, outside #{agent.workspace}'s home network. Approve the bridge or disconnect it.",
      url: Rails.application.routes.url_helpers.agent_channels_path(agent), tag: "concourse-bridge-#{id}"
  end
end
