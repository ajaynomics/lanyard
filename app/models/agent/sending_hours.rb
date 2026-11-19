# When the agent's mail to people outside the install may go (docs/email.md,
# "Sending hours"): from a start until an end, local times every day in a
# time zone, an end before the start running past midnight. Unset, any hour.
# Mail allowed outside them is held until the next start (HeldEmail).
module Agent::SendingHours
  extend ActiveSupport::Concern

  TIME = /\A([01]\d|2[0-3]):[0-5]\d\z/

  included do
    normalizes :send_from, :send_until, :send_time_zone, with: -> { it.strip.presence }
    validates :send_from, :send_until, format: { with: TIME, message: "must be a time such as 08:00" }, allow_nil: true
    validate :sending_hours_whole, if: -> { send_from || send_until || send_time_zone }
  end

  def sending_hours? = send_from.present? && send_until.present? && send_time_zone.present?

  def sending_hours_label = "#{send_from} to #{send_until}, #{send_time_zone}"

  # Nil while mail may go; otherwise when it next may, at the start's local
  # time on that day, whatever a daylight-saving change does between.
  def held_until(now = Time.current)
    return unless sending_hours?
    zone = ActiveSupport::TimeZone[send_time_zone]
    local = now.in_time_zone(zone)
    start, finish = [ send_from, send_until ].map { at(zone, local.to_date, it) }
    open = start < finish ? local >= start && local < finish : local >= start || local < finish
    return if open
    local < start ? start : at(zone, local.to_date + 1, send_from)
  end

  private
    def at(zone, date, hours_minutes) = zone.local(date.year, date.month, date.day, *hours_minutes.split(":").map(&:to_i))

    def sending_hours_whole
      return errors.add(:base, "Sending hours need a start, an end and a time zone") unless sending_hours?
      errors.add(:send_time_zone, "is not a time zone, such as America/Toronto") unless ActiveSupport::TimeZone[send_time_zone]
      errors.add(:send_until, "must differ from the start") if send_from == send_until
    end
end
