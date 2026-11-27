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
# or has the concourse_ tools; outside its workspace's home network, only once
# the workspace's owner approves it too (Bridge).
#
# Pushable registers for Concourse's pushes and Listening reads the mail; this
# delivers it: each new peer message becomes a message in the
# agent's own thread, marked as untrusted peer mail with its
# sender and task; answers to tasks this agent sent go to the thread or
# branch that sent them, and progress notes on them are only kept on the
# task. The sidecar keeps the first submission of each request id, so a
# sweep that stops halfway is repeated safely.
class ConcourseAgent < ApplicationRecord
  include Bridge, Pushable, Listening

  RECHECK_AFTER = 1.minute

  belongs_to :agent
  broadcasts_refreshes_to :agent
  # Where it stands shows on the agent's status line.
  after_commit -> { agent.conversation&.broadcast_status_line },
    if: -> { saved_change_to_status? || saved_change_to_check_error? || saved_change_to_push_token? || saved_change_to_bridge_approved_at? }

  encrypts :client_secret, :push_token

  enum :status, %w[ admitted awaiting_approval declined disconnected ].index_by(&:itself), validate: true
  JOINED = %w[ admitted awaiting_approval ]
  # On Concourse, or on the way (#joined?).
  scope :joined, -> { where(status: JOINED) }

  normalizes :organization, :handle, :client_id, :client_secret, with: -> { it.strip.presence }
  validates :organization, format: { with: /\A[a-zA-Z0-9_-]{1,100}\z/, message: "must look like acme" }
  validates :handle, format: { with: DurableAssistants::Concourse::Client::HANDLE, message: "must look like acme/assistant" }
  validates :client_id, :client_secret, presence: true

  def client
    DurableAssistants::Concourse::Client.new(organization: organization, handle: handle, client_id: client_id, client_secret: client_secret)
  end

  # Asks Concourse where these credentials stand, and keeps the answer for
  # the page. Admitted, and approved if a bridge, it asks Concourse to ring
  # when there is mail.
  def check
    asked = Time.current
    update!(status: client.standing, checked_at: asked, check_error: nil)
    register_push if speaks? && !pushed?
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
    transaction do
      # Its tasks from before networks are tagged as its own first, so none
      # moves to the identity that becomes first now.
      agent.peer_tasks.where(concourse_agent_id: nil).update_all(concourse_agent_id: id) if first?
      destroy!
    end
  end

  # The oldest of the agent's identities, which also owns its untagged tasks.
  def first? = agent.concourse_agents.first == self

  # This identity's tasks: those tagged with it and, for the first, those from before networks.
  def tasks = agent.peer_tasks.where(concourse_agent_id: first? ? [ id, nil ] : id)

  # On Concourse, or on the way: joining again would make a second agent.
  def joined? = status.in?(JOINED)

  def connected? = speaks? && checked_at.present? && check_error.nil?

  def to_s = "#{handle} in #{organization}"

  private
    # A peer's task: each of the caller's messages not yet passed on goes to
    # the agent's thread, as a pi session gets its mail: the agent is one
    # thread, so every caller reaches the same context, each message marked
    # with who sent it. It waits in the agent's inbox unless it can't wait,
    # as a "stop" can't (#85, receive_in).
    def receive(task)
      return if PeerTask::TERMINAL.include?(task.dig("status", "state"))
      messages = Array(task["history"]).select { it["role"] == "ROLE_USER" && it["messageId"].present? }
      caller = caller_of(task, messages)
      return if caller == handle # one this agent sent
      # Without a caller there is nobody to answer; skip it, never stop the sweep.
      return Rails.logger.warn("Concourse task #{task["id"]} not delivered: no caller") if caller.blank?
      peer_task = tasks.inbound.find_by(task_id: task["id"])
      return if peer_task && messages.all? { peer_task.delivered?(it["messageId"]) }

      peer_task ||= agent.conversation.peer_tasks.create_or_find_by!(task_id: task["id"]) do
        it.direction = "inbound"; it.peer = caller; it.context_id = task["contextId"]; it.state = task.dig("status", "state"); it.concourse_agent = self
      end
      peer_task.update!(state: task.dig("status", "state"))
      messages.reject { peer_task.delivered?(it["messageId"]) }.each do |message|
        # A caller follow-up can leave the task's status timestamp unchanged.
        begin
          receive_in peer_task, message["messageId"], PeerTask.text_of(message), from: "#{caller}, task #{task["id"]}, on network #{organization}",
            answer: "When you have an answer, use concourse_reply with this task_id and an explicit state; ending your turn does not answer it.",
            sent_at: time_of(message["timestamp"])
        rescue Conversation::Submission::Conflict
          # Its id already went with other words, and every retry would say so
          # again: it is passed over, so the messages after it still arrive.
          Rails.logger.warn("Concourse message #{message["messageId"]} on task #{task["id"]} passed over: Conversation::Submission::Conflict")
        end
        peer_task.deliver(message["messageId"])
      end
      # Held for a paused agent: the task stays open, and its sender knows why it waits.
      peer_task.answer("TASK_STATE_WORKING", Conversation::Holding::PAUSED) if agent.paused?
    rescue DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch, Conversation::ImagesRefused, Conversation::Submission::Refused => problem
      # One task this agent cannot take must not hold up the rest; the next sweep tries it again.
      Rails.logger.warn("Concourse task #{task["id"]} not delivered: #{problem.class.name}")
    end

    # A task this agent sent: an answer, a question or an end goes to the
    # conversation that sent it, once per status. A note while the peer still
    # works is only kept on the task, by its id, and starts no turn: most are
    # "still on it", and the agent reads them with concourse_get if it needs
    # to. A note it has yet to see when the task moves on goes before the
    # answer, once. A bare change of state wakes nobody.
    def follow(client, peer_task)
      task = client.task(peer_task.task_id)
      state = task.dig("status", "state")
      peer_task.update!(state: state)
      stamp = task.dig("status", "timestamp").to_s
      settled = (PeerTask::TERMINAL.include?(state) || state == "TASK_STATE_INPUT_REQUIRED") && !peer_task.delivered?(stamp)
      status_id = task.dig("status", "message", "messageId") if task.dig("status", "message", "role") == "ROLE_AGENT"
      from = "#{peer_task.peer}, task #{peer_task.task_id}, which you sent on network #{organization}"
      catch_up(peer_task, task, settled ? status_id : nil)

      replies_of(task).each do |message|
        next if peer_task.delivered?(message["messageId"]) || (settled && message["messageId"] == status_id)
        unless state == "TASK_STATE_WORKING"
          receive_in peer_task, message["messageId"], PeerTask.text_of(message), from: from,
            answer: "A note it wrote while it worked; the task has moved on since. Nothing to answer unless it asks.",
            sent_at: time_of(message["timestamp"] || (stamp if message["messageId"] == status_id))
        end
        peer_task.deliver(message["messageId"])
      end
      return unless settled

      # The status message's words come whole, even when it repeats a note:
      # notes kept while the peer worked never reached the agent.
      summary = PeerTask.summary(task)
      receive_in peer_task, stamp, [ summary[:answer], *summary[:artifacts] ].compact.join("\n\n"), from: from,
        answer: "It #{state == "TASK_STATE_INPUT_REQUIRED" ? "asks a question" : "is settled"}: #{state}.#{" To answer, use concourse_send with this task_id." if state == "TASK_STATE_INPUT_REQUIRED"}",
        sent_at: time_of(stamp)
      peer_task.deliver(stamp)
      peer_task.deliver(status_id) if status_id
    rescue DurableAssistants::Concourse::Client::Error => problem
      raise unless problem.status == 404
    rescue Conversation::Submission::Refused => problem
      Rails.logger.warn("Concourse task #{peer_task.task_id} not delivered: #{problem.class.name}")
    end

    # The peer's messages on a task, oldest first, each with an id and words.
    # Concourse's history holds them all; status.message repeats the newest.
    def replies_of(task)
      messages = Array(task["history"]) + [ task.dig("status", "message") ].compact
      messages.select { it["role"] == "ROLE_AGENT" && it["messageId"].present? && PeerTask.text_of(it).present? }.uniq { it["messageId"] }
    end

    # A task sent before progress notes were passed on (#66): the notes it
    # holds count as seen, so none arrives late; only an answer still to
    # come does.
    def catch_up(peer_task, task, pending_answer)
      return if peer_task.notes_followed?
      seen = replies_of(task).map { it["messageId"] } - [ pending_answer ]
      peer_task.update!(notes_followed: true, delivered_ids: peer_task.delivered_ids | seen)
    end

    # Who sent a task. Concourse names them in the task's metadata, as
    # concourse.caller or, on some tasks, concourse.participants' caller; each
    # message also carries its sender.
    def caller_of(task, messages)
      metadata = task["metadata"] || {}
      [ metadata["concourse.caller"], metadata.dig("concourse.participants", "caller", "handle"),
        *messages.map { it.dig("metadata", "concourse.sender", "handle") } ].find(&:present?).to_s
    end

    # A peer's mail goes by the one rule for every channel (Conversation#receive):
    # it waits in the agent's inbox unless it can't. An answer on a task the
    # agent sent itself is what it asked for, so it goes in at the agent's
    # next step.
    def receive_in(peer_task, event, text, from:, answer:, sent_at: nil)
      peer_task.conversation.receive(text, from: from, via: "Concourse mail", answer: answer, sent_at: sent_at,
        when_busy: ("steer" if peer_task.direction == "outbound"), request_id: peer_task.request_id_for(event))
    end

    def time_of(value) = (Time.iso8601(value.to_s) rescue nil)
end
