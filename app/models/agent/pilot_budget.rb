# These are ceilings for new pilot work, not estimates of anyone's provider bill.
class Agent::PilotBudget < ApplicationRecord
  self.table_name = "agent_pilot_budgets"

  KINDS = { "voice" => "Voice", "computer" => "Computer" }.freeze
  LIMIT = 5_000
  THRESHOLDS = [ 50, 80 ].freeze

  belongs_to :agent
  has_many :reservations, class_name: "Agent::PilotBudget::Reservation", foreign_key: :pilot_budget_id, inverse_of: :pilot_budget, dependent: :delete_all
  has_many :alerts, class_name: "Agent::PilotBudget::Alert", foreign_key: :pilot_budget_id, inverse_of: :pilot_budget, dependent: :delete_all

  validates :kind, inclusion: { in: KINDS.keys }
  validates :month, presence: true

  def self.month_at(time)
    time.utc.to_date.beginning_of_month
  end

  # The caller may start external work only if this returns a new reservation.
  # An uncertain or duplicate start must be reconciled, never started again.
  def reserve(request_key, maximum_cents)
    return unless request_key.is_a?(String) && request_key.bytesize.in?(1..128)
    return unless maximum_cents.is_a?(Integer) && maximum_cents.in?(1..LIMIT)

    agent.with_lock do
      reload
      same_kind = agent.pilot_budgets.where(kind: kind)
      next unless month == self.class.month_at(Time.current)
      next if same_kind.joins(:reservations).where(pilot_budget_reservations: { request_key: request_key }).exists?
      next if maximum_cents > totals.last

      reservations.create!(request_key: request_key, maximum_cents: maximum_cents)
    end
  end

  # Nil means no trustworthy final price yet. A provider that exceeds a
  # reservation breaks its cost guarantee; retain the charge and stop work.
  def settle(request_key, actual_cents)
    return false unless actual_cents.is_a?(Integer) && actual_cents.in?(0..2_147_483_647)

    agent.with_lock do
      reload
      reservation = reservations.find_by(request_key: request_key)
      next false unless reservation
      maximum = reservation.maximum_cents
      if reservation.actual_cents.nil?
        reservation.update!(actual_cents: actual_cents)
        update!(blocked: true) if actual_cents > maximum
        reached = THRESHOLDS.select { |threshold| spent_cents * 100 >= LIMIT * threshold }
        reached.each { |threshold| alerts.find_or_create_by!(threshold: threshold) }
      end
      reservation.actual_cents == actual_cents && actual_cents <= maximum
    end
  end

  def totals
    spent, held = reservations.pick(Arel.sql("COALESCE(SUM(actual_cents), 0)"),
      Arel.sql("COALESCE(SUM(CASE WHEN actual_cents IS NULL THEN maximum_cents ELSE 0 END), 0)"))
    [ spent, held, admission_blocked? ? 0 : [ LIMIT - spent - held, 0 ].max ]
  end

  def admission_blocked?
    same_kind = agent.pilot_budgets.where(kind: kind)
    same_kind.where(blocked: true).exists? ||
      same_kind.where.not(id: id).joins(:reservations).where(pilot_budget_reservations: { actual_cents: nil }).exists?
  end

  def brief_line
    "#{KINDS.fetch(kind)}: #{dollars(spent_cents)} used of #{dollars(LIMIT)} this month"
  end

  private
    def spent_cents = reservations.sum(:actual_cents)

    def dollars(cents) = format("$%d.%02d", *cents.divmod(100))
end
