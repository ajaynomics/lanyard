# One step of a Workflow::Run: a task, run as a background helper (Helper)
# that the sidecar starts under a call named for the step, so its calls and
# approvals reach Rails as `<step call>/<call>` and show under the step.
#
# Waiting (pending), then running, then done or failed, or cancelled with its
# run, or skipped when a pipeline stopped before it. `started_at` is when the
# sidecar said it had started the helper: a running step without it is asked
# for again, which the sidecar answers without starting a second.
class Workflow::Step < ApplicationRecord
  STATES = %w[ pending running done failed cancelled skipped ].freeze
  ENDED = %w[ done failed cancelled skipped ].freeze

  belongs_to :run, class_name: "Workflow::Run", inverse_of: :steps
  enum :state, STATES.index_by(&:itself), default: :pending, validate: true

  delegate :conversation, :workflow, to: :run

  validates :task, presence: true

  before_create { self.call_id ||= "workflow-#{run_id}-#{position}" }
  after_commit -> { run.show }, on: :update

  def ended? = state.in?(ENDED)

  def startable? = pending? || (running? && started_at.nil?)

  # Asks the sidecar for its helper. False only when there is no room for
  # another helper now, so the run tries again once one ends.
  def start
    return true unless claim
    conversation.start_helper(call_id, task: task, context: [ workflow.context, context ].compact_blank.join("\n\n").presence,
      model: model, thinking: thinking_level)
    Helper.started(conversation, call_id: call_id, task: task)
    update!(started_at: Time.current)
    stop if reload.cancelled?
    true
  rescue DurableAssistants::PiDurable::Client::Error => error
    raise unless error.status.to_i.between?(400, 499)
    return wait_for_room if error.status == 429
    finish(state: "failed", reason: "it couldn't start (#{error.category || error.status})")
    WorkflowRunJob.perform_later(run)
    true
  end

  # How its helper ended (Helper#deliver), once; the run moves on in a job.
  def take(helper)
    with_lock do
      finish(state: helper.done? ? "done" : "failed", answer: helper.answer, reason: (helper.why if helper.failed?)) if running?
    end
  end

  # Stops its helper in the sidecar, whether or not Rails has heard from it.
  def stop
    if helper&.running?
      helper.cancel
    else
      conversation.cancel_helper(call_id)
    end
  rescue DurableAssistants::PiDurable::Client::Error => error
    raise unless error.status == 404
  ensure
    conversation.helpers.running.where(call_id: call_id).update_all(state: "cancelled", finished_at: Time.current)
    conversation.helpers.where(call_id: call_id, told_at: nil).update_all(told_at: Time.current)
  end

  def helper = conversation.helpers.find_by(call_id: call_id)

  # In a pipeline, the step before it while that one hasn't ended; otherwise
  # it waits only for room for another helper.
  def waits_for = (run.steps.find { it.position == position - 1 && !it.ended? } if run.pipeline?)

  # The agent's own tools its helper called: ledger rows, listed under the step.
  def invocations = conversation.invocations.where("call_id LIKE ?", "#{self.class.sanitize_sql_like(call_id)}/%").order(:id)

  def took = (finished_at - started_at if started_at && finished_at)

  # What it found, or why not, for the run's one message to the agent.
  def report
    text = case state
    when "done" then answer.to_s.first(Workflow::Run::ANSWER_LIMIT)
    when "failed" then "It stopped without an answer: #{reason}."
    when "skipped" then "Not run: a step before it failed."
    else "It didn't finish."
    end
    "## Step #{position}: #{task.squish.truncate(200)}\n\n#{text}"
  end

  private
    def claim
      with_lock do
        next false unless startable?
        update!(state: "running") if pending?
        true
      end
    end

    # Read afresh: another job may have started it meanwhile.
    def wait_for_room
      with_lock { update!(state: "pending") if running? && started_at.nil? }
      false
    end

    def finish(**attributes)
      update!(started_at: started_at || Time.current, finished_at: Time.current, **attributes)
    end
end
