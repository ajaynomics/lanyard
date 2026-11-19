# A place a task's reminder fires on arriving at or leaving, as iOS
# Reminders stores it: its own alarm, beside any alarm at a time. Places are
# never looked up. They are learned from the location reminders already on
# the agent's task lists, most often set on a phone, and written back exactly
# as stored there, so a phone shows the place it knows (docs/calendar.md).
class Tool::Calendar::Place
  PROXIMITIES = { "arrive" => "ARRIVE", "leave" => "DEPART" }.freeze
  # Reminders gives a location alarm this time, long past, so it fires only on arriving or leaving.
  TRIGGER = "19760401T005545Z"

  # The saved places, by name in lower case: every place on a location alarm in the agent's task lists.
  def self.saved(caldav)
    lists = caldav.lists.select { it[:kinds].include?("tasks") }.pluck(:list)
    lists.flat_map { |list| caldav.items(list, "tasks").flat_map { |_, _, calendar| calendar.todos.flat_map(&:alarms) } }
      .filter_map { on(it) }.index_by { it.title.downcase }
  end

  def self.alarm?(alarm) = alarm.custom_property("x_apple_proximity").any?

  # The place a location alarm names, and when it fires: [place, "arrive" or "leave"].
  def self.of(component)
    component.alarms.each do |alarm|
      place = on(alarm) or next
      return [ place, PROXIMITIES.key(alarm.custom_property("x_apple_proximity").first.to_s.upcase) || "arrive" ]
    end
    nil
  end

  def self.on(alarm)
    where = alarm.custom_property("x_apple_structured_location").first
    new(where) if alarm?(alarm) && where.to_s.match?(/\Ageo:-?[\d.]+,-?[\d.]+\z/) && where.ical_params["x-title"].present?
  end

  def initialize(where) = @where = where

  def title = Array(@where.ical_params["x-title"]).join(",")

  # Replaces the component's location alarm with one firing on arriving at or leaving this place.
  def alarm!(component, proximity)
    component.alarms.reject! { self.class.alarm?(it) }
    component.alarm do |alarm|
      uid = SecureRandom.uuid.upcase
      alarm.action = "DISPLAY"
      alarm.description = "Reminder"
      alarm.trigger = Icalendar::Values::DateTime.new(TRIGGER)
      alarm.append_custom_property("uid", uid)
      alarm.append_custom_property("x_apple_proximity", PROXIMITIES.fetch(proximity))
      alarm.append_custom_property("x_apple_structured_location", Icalendar::Values::Uri.new(@where.value, Icalendar::DowncasedHash({ "value" => "URI" }).merge(@where.ical_params)))
      alarm.append_custom_property("x_wr_alarmuid", uid)
    end
  end
end
