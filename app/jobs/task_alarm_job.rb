# One agent's own task lists, queued each minute by TaskAlarmSweepJob: every
# alarm that has just come due starts a turn for it (Agent::TaskAlarm). One
# read of an agent at a time, so a read still running when the next is queued
# drops the next.
class TaskAlarmJob < ApplicationJob
  limits_concurrency key: ->(agent) { agent }, duration: 5.minutes, on_conflict: :discard

  def perform(agent)
    # Waiting on the person, or a run Rails can't vouch for yet, counts as
    # busy too: the alarm is still within the lookback on a later minute, and
    # its id sees to it that the agent wakes once.
    return if agent.conversation.status.in?(%w[ running waiting unknown ])
    Agent::TaskAlarm.due(agent).each(&:wake)
  rescue DurableAssistants::Caldav::Error, DurableAssistants::PiDurable::Client::Error,
         Conversation::Mismatch, Conversation::Submission::Refused => problem
    # One agent whose server or thread cannot be reached must not hold up the
    # rest; its alarm stays due until it falls out of the lookback.
    Rails.logger.warn("Task alarms not delivered for agent #{agent.id}: #{problem.class.name}")
  end
end
