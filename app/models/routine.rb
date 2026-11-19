require "fugit"

# Something that wakes an agent: a prompt sent to its thread on a schedule,
# written as Solid Queue writes one ("every weekday at 8am", or cron), in the
# agent's time zone, or once at a time (`once_at`, "Thursday at 3"), after
# which it is gone. The agent sets its routines when asked (Tool::AddRoutine);
# the person sees, pauses and deletes them on its page. RoutineJob delivers
# them: never while the agent is busy, and a run missed while it was busy or
# the app was down happens once, not once per miss.
class Routine < ApplicationRecord
  # The most often a routine may run: each run costs a model turn.
  SHORTEST_GAP = 5.minutes
  PROMPT_LIMIT = 4_000

  belongs_to :agent
  broadcasts_refreshes_to :agent

  scope :active, -> { where(paused_at: nil) }
  scope :due, -> { active.where(next_run_at: ..Time.current) }

  validates :prompt, presence: true, length: { maximum: PROMPT_LIMIT }
  validate :schedule_is_readable, unless: :once?
  validate :once_is_ahead, if: -> { once? && once_at_changed? }
  before_validation :pin, if: :once?
  before_save :plan, if: -> { schedule_changed? || once_at_changed? || paused_at_changed? }

  # A time as the agent writes it: "2026-11-19T15:00" is 3pm in its zone; an
  # offset, if given, is kept. nil for one it can't read, 30 February among them.
  def self.local_time(text, zone)
    return unless text.to_s.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d/)
    DateTime.iso8601(text)
    (ActiveSupport::TimeZone[zone] || ActiveSupport::TimeZone["UTC"]).iso8601(text)
  rescue ArgumentError
    nil
  end

  def self.in_words(time) = time.strftime(time.year == Time.current.in_time_zone(time.time_zone).year ? "%a %-d %b at %H:%M" : "%a %-d %b %Y at %H:%M")

  def paused? = paused_at.present?
  def once? = once_at.present?

  # How the person and the agent read it: its schedule, or its one time.
  def in_words = once? ? "once, #{self.class.in_words(once_at.in_time_zone(zone))}" : schedule

  # The agent's thread gets the prompt, from its schedule; the next run is
  # the first after now, so however many were missed this is the one. Its
  # agent paused, one run waits among the held messages, however many come due.
  # A one-off has had its run then, held or not, and goes.
  def run
    deliver unless waiting?
    once? ? destroy! : update!(next_run_at: next_time)
  end

  def waiting? = agent.conversation.held.exists?([ "request_id LIKE ?", "routine:#{id}:%" ])

  def next_time(after = Time.current) = once? ? once_at : cron&.next_time(after)&.to_t

  # "8am" moves with the agent's time zone; a one-off's instant does not.
  def replan = update!(next_run_at: paused? ? nil : next_time)

  private
    def deliver
      agent.conversation.receive(prompt, from: "your schedule (#{in_words})", via: "Routine", trusted: true,
        answer: "Do what it asks; nobody is waiting for a reply.", request_id: "routine:#{id}:#{next_run_at.to_i}", when_busy: "followUp")
      self.last_run_at = Time.current
    end

    def zone = ActiveSupport::TimeZone[agent.time_zone] || ActiveSupport::TimeZone["UTC"]

    # In the agent's own time zone: "8am" is 8am where it is.
    def cron
      parsed = Fugit.parse_cronish(schedule.to_s)
      parsed && Fugit::Cron.parse("#{parsed.to_cron_s} #{zone.tzinfo.name}")
    end

    # Code from before one-offs reads only the schedule: as cron of the one
    # time's minute, hour, day and month it runs the one-off at that minute.
    def pin
      self.schedule = once_at.in_time_zone(zone).strftime("%-M %-H %-d %-m *")
    end

    def plan
      self.next_run_at = paused? ? nil : next_time
    end

    def schedule_is_readable
      first = next_time
      return errors.add(:schedule, "isn't one I can read; try \"every weekday at 8am\" or \"every monday at 9:30\"") unless first
      errors.add(:schedule, "runs more often than every #{SHORTEST_GAP.inspect}") if next_time(first) - first < SHORTEST_GAP
    end

    def once_is_ahead
      errors.add(:base, "#{self.class.in_words(once_at.in_time_zone(zone))} has passed; give a time in the future") unless once_at.future?
    end
end
