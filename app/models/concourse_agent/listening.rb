# Reading Concourse: its event log, held open or rung by a push, and the
# minute's inbox sweep under both. What it reads is delivered by the model
# (ConcourseAgent#receive, #follow).
module ConcourseAgent::Listening
  extend ActiveSupport::Concern

  OUTBOUND_PER_SWEEP = 20
  LISTEN_FOR = 15.minutes

  # Reads Concourse's event log for LISTEN_FOR: each task an event names is
  # read and delivered (or, if this agent sent it, followed) at once, and the
  # server's cursor moves only after, so a listener that dies hands the same
  # events to the next. The log can miss events and keeps 30 days; the
  # minute's sweep catches anything it misses, and after a gap Concourse no
  # longer covers, the cursor jumps to what it keeps and a sweep runs now.
  # Mail goes in at the agent's next step, mid-turn if it is working
  # (ConcourseAgent#receive). Rung by a push, it reads what is there without
  # waiting, until nothing is new, and stops. One not admitted reads nothing.
  def listen(client = self.client, deadline: LISTEN_FOR.from_now)
    return unless admitted?
    while Time.current < deadline
      page = pushed? ? client.events(wait: 0) : client.events
      break if page["events"].empty? && pushed?
      page["events"].group_by { it["task_id"] }.each do |task_id, events|
        take(client, task_id)
      end
      client.acknowledge(page["cursor"]) if page["events"].any?
    end
  rescue DurableAssistants::Concourse::Client::Error => problem
    raise unless problem.status == 410
    client.acknowledge(client.events(after: 0, wait: 0, limit: 1)["oldest"] - 1)
    ConcourseSweepJob.perform_later(self)
  end

  # Reads the newest page of the inbox and one further back from the
  # cursor, as the Pi connector does, then checks on tasks this agent sent.
  # An agent not yet admitted reads nothing: the sweep only asks again
  # whether it is. Refused outright, it asks where it stands now, in case
  # an owner took it out or Concourse retired it.
  def sweep
    return recheck unless admitted?
    client = self.client
    head = client.inbox
    page = cursor.present? ? client.inbox(cursor) : head
    (page.equal?(head) ? head["tasks"] : head["tasks"] + page["tasks"]).each { receive(it) }
    update!(cursor: page["nextPageToken"].presence)
    tasks.outbound.open.order(:updated_at).limit(OUTBOUND_PER_SWEEP).each { follow(client, it) }
    update!(checked_at: Time.current, check_error: nil)
  rescue DurableAssistants::Concourse::Client::Error => problem
    update!(checked_at: Time.current, check_error: problem.message.truncate(500))
    check if problem.status.in?([ 401, 403 ])
  end

  private
    def take(client, task_id)
      if (peer_task = tasks.outbound.find_by(task_id: task_id))
        follow(client, peer_task)
      else
        receive(client.task(task_id))
      end
    rescue DurableAssistants::Concourse::Client::Error => problem
      raise unless problem.status == 404 # gone, or no longer this agent's to see
    end
end
