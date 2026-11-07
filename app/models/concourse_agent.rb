# An agent's identity on Concourse, the agents' mail network (docs/design/PARITY.md
# §26). The Concourse operator binds a machine client to one named agent in one
# organization (for example `acme/assistant` in `acme`); the owner pastes its
# id and secret here. Access tokens are never stored here, only in Rails.cache
# (DurableAssistants::Concourse::Client). `cursor` is where the inbox sweep goes on
# reading further back.
#
# Mail arrives by sweep (PARITY.md §28): each new peer message becomes a
# message in the agent's own thread, marked as untrusted peer mail with its
# sender and task; answers to tasks this agent sent go to the thread or
# branch that sent them. The sidecar keeps the first submission of each request id, so a
# sweep that stops halfway is repeated safely.
class ConcourseAgent < ApplicationRecord
  OUTBOUND_PER_SWEEP = 20
  LISTEN_FOR = 15.minutes

  belongs_to :agent

  encrypts :client_secret, :push_token

  normalizes :organization, :handle, :client_id, :client_secret, with: -> { it.strip.presence }
  validates :organization, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/, message: "must look like acme" }
  validates :handle, format: { with: DurableAssistants::Concourse::Client::HANDLE, message: "must look like acme/assistant" }
  validates :client_id, :client_secret, presence: true

  def client
    DurableAssistants::Concourse::Client.new(organization: organization, handle: handle, client_id: client_id, client_secret: client_secret)
  end

  # Asks Concourse who these credentials are, and keeps the answer for the
  # page. Connected, it asks Concourse to ring when there is mail.
  def check
    client.identity
    update!(checked_at: Time.current, check_error: nil)
    register_push
    true
  rescue DurableAssistants::Concourse::Client::Error => problem
    update!(checked_at: Time.current, check_error: problem.message.truncate(500))
    false
  end

  def connected? = checked_at.present? && check_error.nil?

  # Concourse rings (ConcoursePushesController) when this agent's events are
  # new, so nothing need hold its event log open. Concourse reaches only a
  # public https address; on any other, or if it says no, the listener stays.
  # Each connection makes a new token, so saving the settings again rotates it.
  def register_push
    url = URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.concourse_push_path(self)).to_s
    return update!(push_token: nil) unless url.start_with?("https://")
    update!(push_token: SecureRandom.base58(32))
    client.push_to(url, token: push_token)
  rescue DurableAssistants::Concourse::Client::Error => problem
    Rails.logger.warn("Concourse push for #{self} not registered: #{problem.message}")
    update!(push_token: nil)
  end

  def pushed? = push_token.present?

  # Concourse stops ringing for an agent taken off it.
  def stop_pushing
    client.stop_pushing if pushed?
  rescue DurableAssistants::Concourse::Client::Error => problem
    Rails.logger.warn("Concourse push for #{self} not removed: #{problem.message}")
  end

  # Reads Concourse's event log for LISTEN_FOR: each task an event names is
  # read and delivered (or, if this agent sent it, followed) at once, and the
  # server's cursor moves only after, so a listener that dies hands the same
  # events to the next. The log can miss events and keeps 30 days; the
  # minute's sweep catches anything it misses, and after a gap Concourse no
  # longer covers, the cursor jumps to what it keeps and a sweep runs now.
  # A peer's "steer" message interrupts the agent's turn; anything else
  # waits for it to finish. Rung by a push, it reads what is there without
  # waiting, until nothing is new, and stops.
  def listen(client = self.client, deadline: LISTEN_FOR.from_now)
    while Time.current < deadline
      page = pushed? ? client.events(wait: 0) : client.events
      break if page["events"].empty? && pushed?
      page["events"].group_by { it["task_id"] }.each do |task_id, events|
        take(client, task_id, steer: events.any? { it["type"] == "message" && it["delivery"] == "steer" })
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
  def sweep
    client = self.client
    head = client.inbox
    page = cursor.present? ? client.inbox(cursor) : head
    (page.equal?(head) ? head["tasks"] : head["tasks"] + page["tasks"]).each { receive(it) }
    update!(cursor: page["nextPageToken"].presence)
    agent.peer_tasks.outbound.open.order(:updated_at).limit(OUTBOUND_PER_SWEEP).each { follow(client, it) }
    update!(checked_at: Time.current, check_error: nil)
  rescue DurableAssistants::Concourse::Client::Error => problem
    update!(checked_at: Time.current, check_error: problem.message.truncate(500))
  end

  def to_s = "#{handle} in #{organization}"

  private
    def take(client, task_id, steer:)
      if (peer_task = agent.peer_tasks.outbound.find_by(task_id: task_id))
        follow(client, peer_task)
      else
        receive(client.task(task_id), when_busy: steer ? "steer" : "followUp")
      end
    rescue DurableAssistants::Concourse::Client::Error => problem
      raise unless problem.status == 404 # gone, or no longer this agent's to see
    end

    # A peer's task: each of the caller's messages not yet passed on goes to
    # the agent's thread, as a pi session gets its mail: the agent is one
    # thread, so every caller reaches the same context, each message marked
    # with who sent it.
    def receive(task, when_busy: "followUp")
      return if PeerTask::TERMINAL.include?(task.dig("status", "state"))
      return if task.dig("metadata", "concourse.caller") == handle # one this agent sent
      caller = task.dig("metadata", "concourse.caller").to_s
      messages = Array(task["history"]).select { it["role"] == "ROLE_USER" && it["messageId"].present? }
      peer_task = agent.peer_tasks.inbound.find_by(task_id: task["id"])
      return if peer_task && messages.all? { peer_task.delivered?(it["messageId"]) }

      peer_task ||= agent.conversation.peer_tasks
        .create_or_find_by!(task_id: task["id"]) { it.direction = "inbound"; it.peer = caller; it.context_id = task["contextId"]; it.state = task.dig("status", "state") }
      peer_task.update!(state: task.dig("status", "state"))
      messages.reject { peer_task.delivered?(it["messageId"]) }.each do |message|
        receive_in peer_task, "#{task["id"]}\n#{message["messageId"]}", PeerTask.text_of(message), from: "#{caller}, task #{task["id"]}",
          answer: "When you have an answer, use concourse_reply with this task_id and an explicit state; ending your turn does not answer it.", when_busy: when_busy
        peer_task.deliver(message["messageId"])
      end
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch, Conversation::ImagesRefused => problem
      # One task this agent cannot take must not hold up the rest; the next sweep tries it again.
      Rails.logger.warn("Concourse task #{task["id"]} not delivered: #{problem.class.name}")
    end

    # A task this agent sent: an answer, a question or an end goes to the
    # conversation that sent it, once per status.
    def follow(client, peer_task)
      task = client.task(peer_task.task_id)
      state = task.dig("status", "state")
      peer_task.update!(state: state)
      stamp = task.dig("status", "timestamp").to_s
      return unless PeerTask::TERMINAL.include?(state) || state == "TASK_STATE_INPUT_REQUIRED"
      return if peer_task.delivered?(stamp)

      summary = PeerTask.summary(task)
      receive_in peer_task, "#{peer_task.task_id}\n#{stamp}", [ summary[:answer], *summary[:artifacts] ].compact.join("\n\n"),
        from: "#{peer_task.peer}, task #{peer_task.task_id}, which you sent",
        answer: "It #{state == "TASK_STATE_INPUT_REQUIRED" ? "asks a question" : "is settled"}: #{state}.#{" To answer, use concourse_send with this task_id." if state == "TASK_STATE_INPUT_REQUIRED"}"
      peer_task.deliver(stamp)
    rescue DurableAssistants::Concourse::Client::Error => problem
      raise unless problem.status == 404
    end

    def receive_in(peer_task, event, text, from:, answer:, when_busy: "followUp")
      peer_task.conversation.receive(text, from: from, via: "Concourse mail", answer: answer, when_busy: when_busy,
        request_id: "concourse:#{Digest::SHA256.hexdigest(event)}")
    end
end
