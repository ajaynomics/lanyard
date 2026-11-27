# Every minute (config/recurring.yml), deliberately global: every agent with
# calendars of its own and an address to mail gets a read of its own lists
# (AlarmMailerJob), so one calendar server that is slow or down holds up no
# other agent's alarms.
class AlarmSweepJob < ApplicationJob
  limits_concurrency key: "alarms"

  def perform
    return unless ApplicationMailer.delivers? && AlarmMailer.from
    Agent.with_own_calendar.find_each do |agent| # tenancy-ok: the clock reads every owner's agents
      AlarmMailerJob.perform_later(agent) if agent.alarm_calendar? && AlarmMailer.address_of(agent)
    end
  end
end
