# Every minute (config/recurring.yml), deliberately global: each routine that
# is due, whoever owns it, runs unless its agent is busy, and then runs on a
# later minute, once.
class RoutineJob < ApplicationJob
  limits_concurrency key: "routines"

  def perform
    Routine.due.includes(agent: :conversation).find_each do |routine| # tenancy-ok: the clock wakes every owner's agents
      next if routine.agent.conversation.status.in?(%w[ running waiting ])
      routine.run
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch => problem
      # One agent that cannot be reached must not hold up the rest; it stays due.
      Rails.logger.warn("Routine #{routine.id} not run: #{problem.class.name}")
    end
  end
end
