# An agent's identity on Concourse, the agents' mail network: its address (`handle`, for example `acme/iris`) in one organization
# (`acme`), and the machine client Concourse made when the person joined it
# (docs/design.md, "Joining Concourse"). Agents connected before joining
# existed hold a client the Concourse operator bound and the owner pasted; they
# work the same. Access tokens are never stored here, only in Rails.cache
# (DurableAssistants::Concourse::Client). `cursor` is where the inbox sweep goes on
# reading further back.
#
# `status` is where it stands: admitted, waiting for an owner of the
# organization to approve it, declined, or disconnected (Concourse no longer
# accepts its credentials). Only an admitted agent reads mail, is rung for it
# or has the concourse_ tools.
#
# Pushable registers for Concourse's pushes and Listening reads the mail; this
# delivers it: each new peer message becomes a message in the
# agent's own thread, marked as untrusted peer mail with its
# sender and task; answers to tasks this agent sent go to the thread or
# branch that sent them. The sidecar keeps the first submission of each request id, so a
# sweep that stops halfway is repeated safely.
class ConcourseAgent < ApplicationRecord
  include Pushable, Listening

  RECHECK_AFTER = 1.minute

  belongs_to :agent
  broadcasts_refreshes_to :agent
  # Where it stands shows on the agent's status line.
  after_commit -> { agent.conversation&.broadcast_status_line }, if: -> { saved_change_to_status? || saved_change_to_check_error? || saved_change_to_push_token? }

  encrypts :client_secret, :push_token

  enum :status, %w[ admitted awaiting_approval declined disconnected ].index_by(&:itself), validate: true

  normalizes :organization, :handle, :client_id, :client_secret, with: -> { it.strip.presence }
  validates :organization, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/, message: "must look like acme" }
  validates :handle, format: { with: DurableAssistants::Concourse::Client::HANDLE, message: "must look like acme/assistant" }
  validates :client_id, :client_secret, presence: true

  def client
    DurableAssistants::Concourse::Client.new(organization: organization, handle: handle, client_id: client_id, client_secret: client_secret)
  end

  # Asks Concourse where these credentials stand, and keeps the answer for
  # the page. Admitted, it asks Concourse to ring when there is mail.
  def check
    asked = Time.current
    update!(status: client.standing, checked_at: asked, check_error: nil)
    register_push if admitted? && !pushed?
    admitted?
  rescue DurableAssistants::Concourse::Client::Error => problem
    update!(checked_at: asked, check_error: problem.message.truncate(500))
    false
  end

  # Asked again while an owner has yet to approve it, at most once a minute,
  # by the Channels page or the minute's sweep. Declined and disconnected
  # are final: only joining again changes them.
  def recheck
    check if awaiting_approval? && (checked_at.nil? || checked_at <= RECHECK_AFTER.ago)
  end

  # Leaving Concourse (the join contract, G). Concourse retires the agent
  # first, and only then is the credential forgotten, so a refusal keeps it
  # for the person to try again. Pushes stop before, while its token works.
  def disconnect
    stop_pushing
    client.revoke
    destroy!
  end

  # On Concourse, or on the way: joining again would make a second agent.
  def joined? = admitted? || awaiting_approval?

  def connected? = admitted? && checked_at.present? && check_error.nil?

  def to_s = "#{handle} in #{organization}"

  private
    # A peer's task: each of the caller's messages not yet passed on goes to
    # the agent's thread, as a pi session gets its mail: the agent is one
    # thread, so every caller reaches the same context, each message marked
    # with who sent it.
    def receive(task, when_busy: "followUp")
      return if PeerTask::TERMINAL.include?(task.dig("status", "state"))
      messages = Array(task["history"]).select { it["role"] == "ROLE_USER" && it["messageId"].present? }
      caller = caller_of(task, messages)
      return if caller == handle # one this agent sent
      # Without a caller there is nobody to answer; skip it, never stop the sweep.
      return Rails.logger.warn("Concourse task #{task["id"]} not delivered: no caller") if caller.blank?
      peer_task = agent.peer_tasks.inbound.find_by(task_id: task["id"])
      return if peer_task && messages.all? { peer_task.delivered?(it["messageId"]) }

      peer_task ||= agent.conversation.peer_tasks
        .create_or_find_by!(task_id: task["id"]) { it.direction = "inbound"; it.peer = caller; it.context_id = task["contextId"]; it.state = task.dig("status", "state") }
      peer_task.update!(state: task.dig("status", "state"))
      messages.reject { peer_task.delivered?(it["messageId"]) }.each do |message|
        # A message in a task's history carries no time of its own; the task's
        # status changed when its newest message came.
        sent_at = time_of(message["timestamp"] || (task.dig("status", "timestamp") if message == messages.last))
        receive_in peer_task, "#{task["id"]}\n#{message["messageId"]}", PeerTask.text_of(message), from: "#{caller}, task #{task["id"]}",
          answer: "When you have an answer, use concourse_reply with this task_id and an explicit state; ending your turn does not answer it.",
          when_busy: when_busy, sent_at: sent_at
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
        answer: "It #{state == "TASK_STATE_INPUT_REQUIRED" ? "asks a question" : "is settled"}: #{state}.#{" To answer, use concourse_send with this task_id." if state == "TASK_STATE_INPUT_REQUIRED"}",
        sent_at: time_of(stamp)
      peer_task.deliver(stamp)
    rescue DurableAssistants::Concourse::Client::Error => problem
      raise unless problem.status == 404
    end

    # Who sent a task. Concourse names them in the task's metadata, as
    # concourse.caller or, on some tasks, concourse.participants' caller; each
    # message also carries its sender.
    def caller_of(task, messages)
      metadata = task["metadata"] || {}
      [ metadata["concourse.caller"], metadata.dig("concourse.participants", "caller", "handle"),
        *messages.map { it.dig("metadata", "concourse.sender", "handle") } ].find(&:present?).to_s
    end

    def receive_in(peer_task, event, text, from:, answer:, when_busy: "followUp", sent_at: nil)
      peer_task.conversation.receive(text, from: from, via: "Concourse mail", answer: answer, when_busy: when_busy, sent_at: sent_at,
        request_id: "concourse:#{Digest::SHA256.hexdigest(event)}")
    end

    def time_of(value) = (Time.iso8601(value.to_s) rescue nil)
end
