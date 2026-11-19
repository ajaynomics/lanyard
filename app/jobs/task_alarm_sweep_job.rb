# Every minute (config/recurring.yml), deliberately global: every agent with
# calendars of its own gets a read of its own task lists (TaskAlarmJob), so
# one calendar server that is slow or down holds up no other agent's alarms.
class TaskAlarmSweepJob < ApplicationJob
  limits_concurrency key: "task_alarms"

  def perform
    Agent.with_own_calendar.find_each do |agent| # tenancy-ok: the clock reads every owner's agents
      TaskAlarmJob.perform_later(agent) if agent.own_calendar?
    end
  end
end
