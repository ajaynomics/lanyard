# Where a thread stands, from two facts kept apart: whether its own run is
# going (`execution_status`, from the sidecar's frames, its snapshot and an
# accepted send) and whether a card waits on the person (attention, from the
# ledger). A background helper's card can wait after the agent's run has
# ended, so one never stands for the other: a card never starts, ends or
# revives a run, and a run that ends never clears a card.
#
# The status every view reads is this one rule: an unexpired card waiting on
# the person wins as "waiting"; otherwise the run says. A run Rails can't
# vouch for (one that was waiting when this was introduced) is "unknown",
# shown as "Checking run status" until the sidecar is next asked.
class Conversation::Activity
  EXECUTIONS = %w[ unknown idle running error ].freeze
  # What `status` may hold: what code from before execution_status accepts,
  # since both run side by side during a deploy. An unknown run is stored as
  # "running", which that code's sweep also asks about; Conversation#shown_status
  # tells the two apart.
  STATUSES = %w[ idle running waiting error ].freeze

  # The sidecar's snapshot (agent/runtime.mjs `snapshot`), which leaves
  # background helpers out. "waiting" there is the run holding a wait, for a
  # person or an outside call: still running. "stalled" goes to
  # Conversation#recover, its own bounded path.
  SIDECAR = { "idle" => "idle", "done" => "idle", "cancelled" => "idle", "running" => "running", "waiting" => "running",
              "error" => "error", "blocked" => "error" }.freeze

  # A run its agent's pause refused at its next step (agent/runtime.mjs,
  # Agent::Pausable) ended; it did not fail, then or after the resume.
  PAUSED = "paused_by_owner".freeze

  def self.from_sidecar(status, failure: nil) = failure == PAUSED ? "idle" : SIDECAR[status]

  # The whole snapshot. Its "waiting" is a run holding a wait only while one
  # of the calls it waits on is still open here: one whose every wait is on a
  # call already answered (Conversation::AnsweredWaits) says nothing of the
  # run, which Rails can't vouch for ("unknown") until the sidecar, its waits
  # rung, is asked again. The stall guard handles only "stalled", so without
  # this such a thread showed working until its waits expired a day later.
  def self.from_snapshot(state, answered:)
    return "unknown" if state["status"] == "waiting" && answered.all?
    from_sidecar(state["status"], failure: state.dig("failure", "reason"))
  end

  # A frame says whether the run goes; the last (busy: false) says why it stopped, if it failed.
  def self.from_frame(busy:, failure:) = busy ? "running" : from_sidecar(failure.present? ? "error" : "idle", failure: failure)

  attr_reader :conversation

  def initialize(conversation)
    @conversation = conversation
  end

  def status = waiting_on_person? ? "waiting" : conversation.execution_status

  def stored_status = status == "unknown" ? "running" : status

  def waiting_on_person? = conversation.invocations.awaiting_person.where(expires_at: Time.current..).exists?
end
