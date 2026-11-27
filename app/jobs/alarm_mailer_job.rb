# One agent's own calendars and task lists, read each minute (AlarmSweepJob):
# every alarm that came due since the last read is mailed to it (AlarmMailer),
# whether it is busy or not, and the agent's watermark moves past each moment
# only once every alarm due then went. One read of an agent at a time, so a
# read still running when the next is queued drops the next.
#
# After downtime it reads back at most a day, and what came due more than a
# few minutes ago goes in one message rather than one each.
class AlarmMailerJob < ApplicationJob
  CATCH_UP = 24.hours
  LATE = 10.minutes

  limits_concurrency key: ->(agent) { agent }, duration: 5.minutes, on_conflict: :discard

  def perform(agent)
    now = Time.current
    # Its first read starts now: nothing before it was promised to it.
    return agent.update!(alarms_read_until: now) unless agent.alarms_read_until

    late, due = Agent::Alarm.due(agent, from: [ agent.alarms_read_until, now - CATCH_UP ].max, to: now).partition { it.at < now - LATE }
    mailed(agent, late.last.at) { AlarmMailer.missed(agent, late).deliver_now } if late.any?
    due.group_by(&:at).each { |at, alarms| mailed(agent, at) { alarms.each { AlarmMailer.due(agent, it).deliver_now } } }
    agent.update!(alarms_read_until: now)
  rescue DurableAssistants::Caldav::Error, Net::SMTPError, IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => problem
    # One agent whose server cannot be reached must not hold up the rest; its
    # watermark stays where the last mail went, so the next read mails what
    # this one did not. Mailed twice, an alarm keeps its Message-ID (its key)
    # and reaches the thread once.
    Rails.logger.warn("Alarms not mailed for agent #{agent.id}: #{problem.class.name}")
  end

  private
    # The watermark passes a moment only once all that fired then went, so a
    # send that fails is retried and none before it is sent again.
    def mailed(agent, through)
      yield
      agent.update!(alarms_read_until: through)
    end
end
