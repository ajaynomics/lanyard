# Every minute (config/recurring.yml), deliberately global: mail held for its
# agent's sending hours that is now due, whoever's it is (HeldEmail.sweep).
class HeldEmailSweepJob < ApplicationJob
  limits_concurrency key: "held_email_sweep"

  def perform = HeldEmail.sweep
end
