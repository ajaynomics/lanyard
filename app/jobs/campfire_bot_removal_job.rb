# Deactivates a removed agent's Campfire bot, so it leaves every room and its
# key stops working. The agent's bot record is gone by now: its owner and the
# Campfire id say which bot.
class CampfireBotRemovalJob < ApplicationJob
  retry_on DurableAssistants::Campfire::Error, wait: :polynomially_longer, attempts: 5
  discard_on(DurableAssistants::Campfire::Changed) { |_job, changed| Rails.error.report(changed) }

  def perform(user, campfire_id) # user: whose bot it was, for the record
    DurableAssistants::Campfire.admin.deactivate_bot(campfire_id)
  end
end
