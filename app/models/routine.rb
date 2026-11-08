require "fugit"

# Something that wakes an agent: a prompt sent to its thread on a schedule,
# written as Solid Queue writes one ("every weekday at 8am", or cron), in the
# agent's time zone. The agent sets its routines when asked (Tool::AddRoutine);
# the person sees, pauses and deletes them on its page. RoutineJob delivers
# them: never while the agent is busy, and a run missed while it was busy or
# the app was down happens once, not once per miss.
class Routine < ApplicationRecord
  # The most often a routine may run: each run costs a model turn.
  SHORTEST_GAP = 5.minutes
  PROMPT_LIMIT = 4_000

  belongs_to :agent

  scope :active, -> { where(paused_at: nil) }
  scope :due, -> { active.where(next_run_at: ..Time.current) }

  validates :prompt, presence: true, length: { maximum: PROMPT_LIMIT }
  validate :schedule_is_readable
  before_save :plan, if: -> { schedule_changed? || paused_at_changed? }

  def paused? = paused_at.present?

  # The agent's thread gets the prompt, from its schedule; the next run is
  # the first after now, so however many were missed this is the one.
  def run
    agent.conversation.receive(prompt, from: "your schedule (#{schedule})", via: "Routine", trusted: true,
      answer: "Do what it asks; nobody is waiting for a reply.", request_id: "routine:#{id}:#{next_run_at.to_i}")
    update!(last_run_at: Time.current, next_run_at: next_time)
  end

  def next_time(after = Time.current) = cron&.next_time(after)&.to_t

  # "8am" moves with the agent's time zone.
  def replan = update!(next_run_at: paused? ? nil : next_time)

  private
    # In the agent's own time zone: "8am" is 8am where it is.
    def cron
      parsed = Fugit.parse_cronish(schedule.to_s)
      parsed && Fugit::Cron.parse("#{parsed.to_cron_s} #{ActiveSupport::TimeZone[agent.time_zone]&.tzinfo&.name || "UTC"}")
    end

    def plan
      self.next_run_at = paused? ? nil : next_time
    end

    def schedule_is_readable
      first = next_time
      return errors.add(:schedule, "isn't one I can read; try \"every weekday at 8am\" or \"every monday at 9:30\"") unless first
      errors.add(:schedule, "runs more often than every #{SHORTEST_GAP.inspect}") if next_time(first) - first < SHORTEST_GAP
    end
end
