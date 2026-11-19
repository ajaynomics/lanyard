# A helper the agent started in the background (the `subagent` tool with
# `background: true`, agent/subagent.mjs): it works on its task while the
# agent carries on, and its answer comes to the conversation as a message.
# The sidecar runs it and reports here (Sidecar::HelpersController): that it
# is working and on what, then how it ended. A person can tell it something
# while it works, or cancel it.
#
# Running, then done, failed or cancelled; nothing leaves a finished state.
# The answer (or the failure) is handed in once, by request id, and handed
# in again only if Rails could not the first time, so a repeated report
# never delivers twice and a failed delivery is never lost.
class Helper < ApplicationRecord
  include ListedInHelpersPanel

  STATES = %w[ running done failed cancelled ].freeze
  FINISHED = %w[ done failed ].freeze
  # The calls kept for its card, as the sidecar sends them.
  CALLS = 64
  TASK_LIMIT = 10_000
  # What a person tells it at once, and how many of those its card keeps.
  MESSAGE_LIMIT = 4_000
  MESSAGES = 20
  # How many that have ended the Helpers panel lists under the working ones.
  RECENT = 25
  # Reported nothing for this long: the minute's sweep asks the sidecar whether
  # it still runs it. Long enough that a helper just started is found there.
  ASK_AFTER = 10.minutes
  # Reported nothing for this long: stopped and settled, whatever the sidecar
  # says. A real helper is quiet at most while a call waits on a person (a day,
  # Invocation::WAIT) and then while its end report is retried (a day, the
  # sidecar's helperReportForMs); a third day is the margin.
  QUIET = 3.days
  # Why one stopped, in words, by the reason the sidecar reports.
  REASONS = {
    "request_limit" => "it reached its limit of model requests",
    "request_timeout" => "the model sent nothing for five minutes",
    "rate_limited" => "the model's usage limit is reached",
    "credential_missing" => "its model isn't signed in",
    "lost" => "its end never reached here, and the sidecar no longer runs it",
    "quiet" => "it sent no word for three days"
  }.freeze

  belongs_to :conversation
  enum :state, STATES.index_by(&:itself), default: :running, validate: true

  validates :call_id, :task, presence: true

  scope :untold, -> { cancelled.where(told_at: nil) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  # Those that have ended, the latest to end first, for the Helpers panel.
  scope :recent, -> { where.not(state: "running").order(finished_at: :desc, id: :desc).limit(RECENT) }
  # The agent's own, not those working on a workflow's steps, which the panel lists within their run.
  scope :own, -> { where.not(call_id: Workflow::Step.select(:call_id)) } # tenancy-ok: narrows helpers already reached through their owner

  after_commit :show, on: %i[ create update ]
  # A workflow's step's helper is redrawn with its run (Workflow::Run#show).
  after_commit :redraw_helpers_panels, on: %i[ create update ], unless: :workflow_step

  # One just started, by the agent's call (Message) or a workflow's step
  # (Workflow::Step#start): working from now, before the sidecar first reports,
  # so the thread counts it at once. A report may come first; this finds it.
  def self.started(conversation, call_id:, task:)
    conversation.helpers.create_or_find_by!(call_id: call_id) { it.task = task.to_s.first(TASK_LIMIT) }
  end

  # What the sidecar said. A running report brings what the helper is doing;
  # a finished one, how it ended. Either may be the first to arrive.
  # Each report names the model and thinking it runs on (agent/subagent.mjs).
  def self.report(conversation, call_id:, task:, state:, answer: nil, reason: nil, calls: [], count: 0, usage: nil, model: nil, thinking_level: nil)
    helper = started(conversation, call_id: call_id, task: task)
    helper.receive(state: state, answer: answer, reason: reason, calls: calls, count: count, usage: usage, model: model, thinking_level: thinking_level)
    helper
  end

  # Every minute (ConversationRecoveryJob): one whose end report never came
  # stays running, and counted as working, until this settles it as failed,
  # with why, and logs it. Its answer, if it had one, is lost; nothing is run
  # again. One the sidecar can't be asked about now waits for the next minute.
  def self.settle_lost
    running.where(updated_at: ...ASK_AFTER.ago).find_each do |helper| # tenancy-ok: the recurring sweep covers every conversation
      reason = helper.lost_because
      next unless reason
      helper.receive(state: "failed", reason: reason, calls: helper.calls, count: helper.call_count)
      next unless helper.failed? && helper.reason == reason # an end report came first
      Rails.logger.info "Settled helper #{helper.id} (#{helper.call_id}) of conversation #{helper.conversation_id} as failed (#{reason})"
    rescue DurableAssistants::PiDurable::Client::Error
      next
    end
  end

  # "quiet" when it has said nothing for too long, the sidecar told to stop it;
  # "lost" when the sidecar has its task as ended, or has none.
  def lost_because
    if updated_at < QUIET.ago
      conversation.cancel_helper(call_id)
      "quiet"
    elsif conversation.helper_status(call_id) != "running"
      "lost"
    end
  rescue DurableAssistants::PiDurable::Client::Error => error
    raise unless error.status == 404
    "lost"
  end

  def receive(state:, answer: nil, reason: nil, calls: [], count: 0, usage: nil, model: nil, thinking_level: nil)
    with_lock do
      next unless running?
      attributes = { calls: Array(calls), call_count: count.to_i, model: model, thinking_level: thinking_level }.compact
      if state.in?(FINISHED)
        attributes.merge!(state: state, answer: answer, reason: reason, usage: Usage.from(usage), finished_at: Time.current)
        meter(usage)
      end
      update!(attributes)
    end
    deliver
  end

  # The person's Cancel, or the agent's (Tool::CancelHelper). The sidecar
  # stops it and says what it had done; its approval cards are answered for
  # it; the agent hears of the person's at its next turn, and of its own
  # already, so that one is marked told.
  def cancel(by_agent: false)
    return false unless running?
    made = conversation.cancel_helper(call_id)
    with_lock do
      next false unless running?
      update!(state: "cancelled", finished_at: Time.current, calls: Array(made["tools"]).last(CALLS), call_count: made["count"].to_i,
        reason: ("agent" if by_agent), told_at: (Time.current if by_agent))
      conversation.invocations.awaiting_person.where("substr(call_id, 1, ?) = ?", call_id.length + 1, "#{call_id}/").find_each do
        it.update!(state: "failed", error: "#{by_agent ? "The assistant" : "The person"} cancelled the helper that asked.")
      end
      true
    end
  end

  def cancelled_by_agent? = cancelled? && reason == "agent"

  # The person's words for it while it works, which it reads at its next step,
  # as a steer reaches the agent. Kept for its card, and told to the agent with
  # its answer. False once it has finished, as for Cancel.
  def message(text)
    text = text.to_s.strip.first(MESSAGE_LIMIT)
    return false unless running? && text.present?
    return false unless conversation.message_helper(call_id, self.class.steer(text), request_id: "person:#{SecureRandom.uuid}")
    with_lock { update!(messages: (Array(messages) + [ { "text" => text, "at" => Time.current.iso8601 } ]).last(MESSAGES)) }
    true
  end

  # A person's words as the helper reads them: whose they are, and that they
  # change its task only as far as they say.
  def self.steer(text) =
    "[Message from the person the assistant who gave you this task works for, sent while you work] #{text}\n" \
      "It changes your task only as far as it says."

  def finished? = state.in?(FINISHED)

  # The step of a workflow it works on, if it is one (Workflow::Step).
  def workflow_step = conversation.workflow_steps.find_by(call_id: call_id)

  # The task in quotes, for a sentence that goes on after it.
  def quoted_task = "“#{task.squish.truncate(200).delete_suffix(".")}”"

  def why = REASONS.fetch(reason.to_s) { reason.to_s.tr("_", " ") }

  # The calls it had made that came back, for its card after a Cancel.
  def calls_done = Array(calls).select { it["status"] == "done" }

  # The note for the agent's next turn (Conversation#submit), on the helpers
  # the person cancelled since. Message#content takes it off for the person.
  def self.cancellations_for_agent(helpers)
    lines = helpers.map do |helper|
      done = helper.calls_done.map { it["name"] }.tally.map { |name, times| times > 1 ? "#{name} (#{times} times)" : name }
      "The person cancelled the helper working on #{helper.quoted_task}. " +
        (done.any? ? "Before that it had run #{done.to_sentence}." : "It had done nothing yet.")
    end
    "\n\n<helpers_cancelled>\n#{lines.join("\n")}\n</helpers_cancelled>"
  end

  private
    # A background helper runs apart from its thread, so its thread's totals
    # never count it: what it used is recorded here, once, as it ends.
    def meter(usage)
      rows = Usage.rows(usage)
      ModelUsage.record(conversation.agent, rows, conversation: conversation, helper: self) if rows
    end

    # A workflow's step hands its run the answer instead (Workflow::Step#take),
    # and the run tells the agent once every step has ended. A helper that
    # ends makes room for a workflow's step waiting on one.
    def deliver
      return unless finished? && delivered_at.nil?
      if (step = workflow_step)
        step.take(self)
      else
        conversation.receive(from: "the helper you started", via: "Helper", request_id: "helper:#{call_id}", when_busy: "steer", source: { helper_id: id }) do
          [ done? ? answer.to_s : "The helper stopped without an answer: #{why}.",
            "It reports on the task you gave it in the background, #{quoted_task}.#{told} Tell the person what matters." ]
        end
      end
      update!(delivered_at: Time.current)
      conversation.workflow_runs.running.each { WorkflowRunJob.perform_later(it) }
    end

    # What the person told it while it worked, for the agent its answer goes to.
    def told
      said = Array(messages).map { "“#{it["text"].to_s.squish.truncate(300)}”" }
      " While it worked, the person told it #{said.to_sentence}." if said.any?
    end

    def show
      if (step = workflow_step)
        step.run.show
      else
        broadcast_replace_to conversation, target: "#{Invocation.dom_target(call_id)}_helper", partial: "helpers/helper", locals: { helper: self }
      end
      conversation.broadcast_status_line if saved_change_to_state? || previously_new_record?
    end
end
