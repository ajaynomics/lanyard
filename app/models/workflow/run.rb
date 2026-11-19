# One run of a Workflow: its steps, each a background helper (Workflow::Step),
# and where it stands. Running until every step has ended, then done, or
# failed if a step failed; or cancelled by the person. Nothing leaves an end.
#
# It moves forward in #advance, which starts what may start now and finishes
# the run once nothing is left. A job asks it when it starts, when a step
# ends, and every minute (WorkflowSweepJob), so a restart of the app or the
# sidecar loses nothing: what was asked is asked again, and a step's helper,
# named by the step, is never started twice. Its answers reach the agent
# once, as one message, by request id.
class Workflow::Run < ApplicationRecord
  include ListedInHelpersPanel

  STATES = %w[ running done failed cancelled ].freeze
  # The most of one step's answer the agent is handed with the others.
  ANSWER_LIMIT = 20_000
  # How many that have ended the Helpers panel lists under the running ones.
  RECENT = 10

  belongs_to :workflow
  has_many :steps, -> { order(:position) }, class_name: "Workflow::Step", dependent: :delete_all, inverse_of: :run
  enum :state, STATES.index_by(&:itself), default: :running, validate: true

  delegate :conversation, :name, :pipeline?, :shape, to: :workflow

  # Running, or ended and not yet handed to the agent.
  scope :unsettled, -> { where(state: "running").or(where(state: %w[ done failed ], delivered_at: nil)) }
  scope :untold, -> { cancelled.where(told_at: nil) }
  # For the Helpers panel: those running, newest first, then those that ended lately.
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }
  scope :recent, -> { where.not(state: "running").order(finished_at: :desc, id: :desc).limit(RECENT) }

  after_create_commit -> { WorkflowRunJob.perform_later(self) }
  after_create_commit :redraw_helpers_panels
  after_commit :show, on: :update

  def advance
    return deliver if finished?
    return unless running?
    # A paused agent's helpers would only be refused their first request; they start once it is resumed.
    return if conversation.agent.paused?
    startable.each { break unless it.start }
    reload
    finish if running? && steps.all?(&:ended?)
  end

  def finished? = done? || failed?

  # The person's Cancel: every step's helper stops, and those not started
  # never will. The agent hears with whatever it is told next, as it does of
  # a helper the person cancelled (Conversation#submit).
  def cancel
    return false unless running?
    steps.select(&:running?).each(&:stop)
    with_lock do
      next false unless running?
      steps.reject(&:ended?).each { it.update!(state: "cancelled", finished_at: Time.current) }
      update!(state: "cancelled", finished_at: Time.current)
    end
  end

  def done_count = steps.count(&:done?)

  # Its steps at work and each one's helper, in order, for a Message to each
  # in the Helpers panel (workflow/runs/_row).
  def working_helpers
    working = steps.select(&:running?)
    helpers = conversation.helpers.running.where(call_id: working.map(&:call_id)).index_by(&:call_id)
    working.filter_map { |step| [ step, helpers[step.call_id] ] if helpers[step.call_id] }.to_h
  end

  def quoted_name = "“#{name.squish.truncate(100)}”"

  # The note for the agent's next turn, on the runs the person cancelled.
  def self.cancellations_for_agent(runs)
    lines = runs.map do |run|
      done = run.steps.select(&:done?).map(&:position)
      "The person cancelled the workflow #{run.quoted_name}. " +
        (done.any? ? "#{"Step".pluralize(done.size)} #{done.to_sentence} had finished; nothing more comes from it." : "No step had finished.")
    end
    "\n\n<workflows_cancelled>\n#{lines.join("\n")}\n</workflows_cancelled>"
  end

  # The app and the job process both redraw a run. Each draws it afresh under
  # the run's lock (with_lock reloads it), so they take turns and the last one
  # sent shows everything saved before it, never an older copy. So are the
  # Helpers panels.
  def show
    with_lock do
      broadcast_replace_to conversation, target: ActionView::RecordIdentifier.dom_id(self), partial: "workflow/runs/run", locals: { run: self }
      redraw_helpers_panels
    end
  end

  private
    # A fan-out's steps all at once, as room allows; a pipeline's next one,
    # given what the step before found, unless a step before it failed.
    def startable
      return steps.select(&:startable?) unless pipeline?
      return skip_the_rest if steps.any?(&:failed?)
      step = steps.find { !it.ended? }
      return [] unless step&.startable?
      step.update!(context: steps.find_by(position: step.position - 1)&.answer.to_s.first(ANSWER_LIMIT).presence) if step.pending?
      [ step ]
    end

    def skip_the_rest
      steps.select(&:pending?).each { it.update!(state: "skipped", finished_at: Time.current) }
      []
    end

    def finish
      update!(state: steps.all?(&:done?) ? "done" : "failed", finished_at: Time.current)
      deliver
    end

    def deliver
      return if delivered_at
      conversation.receive(from: "the workflow you started", via: "Workflow", request_id: "workflow:#{id}", when_busy: "steer", source: { workflow_run_id: id }) do
        [ report, "It reports on the workflow you started in the background, #{quoted_name}. Tell the person what matters." ]
      end
      update!(delivered_at: Time.current)
    end

    def report
      head = done? ? "Every step finished." : "It stopped: a step failed."
      [ head, *steps.map(&:report) ].join("\n\n")
    end
end
