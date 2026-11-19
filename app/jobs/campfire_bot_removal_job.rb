# Deactivates a removed agent's Campfire bot, so it leaves every room and its
# key stops working. The agent's bot record is gone by now: its workspace says
# which Campfire, the Campfire id which bot. A workspace's own Campfire signs
# in as the vault lets the agents' shared user, the agent being gone too.
# Asked before workspaces had Campfires, the first argument is its person.
class CampfireBotRemovalJob < ApplicationJob
  retry_on DurableAssistants::Campfire::Error, wait: :polynomially_longer, attempts: 5
  discard_on(DurableAssistants::Campfire::Changed) { |_job, changed| Rails.error.report(changed) }

  def perform(workspace, campfire_id)
    campfire = workspace.is_a?(Workspace) ? workspace.campfire(as: nil) : DurableAssistants::Campfire.install
    campfire.admin.deactivate_bot(campfire_id)
  end
end
