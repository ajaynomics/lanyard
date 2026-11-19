# A reminder set on a phone to fire on arriving somewhere, shaped as iOS
# Reminders stores one (docs/calendar.md), with a made-up place. Servers
# reorder properties and refold lines, so alarms are compared as their
# unfolded property lines, not as bytes.
module LocationAlarmTestHelper
  PHONE_PLACE = "X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-ADDRESS=12 Example Rd\\\\nSpringfield ZZ 00000\\\\nUtopia;" \
    "X-APPLE-RADIUS=100;X-APPLE-REFERENCEFRAME=1;X-TITLE=Corner Shop:geo:12.345678,-98.765432".freeze

  def phone_reminder(uid: "phone-1", title: "Buy stamps", proximity: "ARRIVE", place: PHONE_PLACE)
    <<~ICS.gsub("\n", "\r\n")
      BEGIN:VCALENDAR
      VERSION:2.0
      PRODID:-//Apple Inc.//iOS 26//EN
      BEGIN:VTODO
      UID:#{uid}
      DTSTAMP:20261101T120000Z
      SUMMARY:#{title}
      STATUS:NEEDS-ACTION
      BEGIN:VALARM
      ACTION:DISPLAY
      DESCRIPTION:Reminder
      TRIGGER;VALUE=DATE-TIME:19760401T005545Z
      UID:0A1B2C3D-0000-4000-8000-000000000001
      X-APPLE-PROXIMITY:#{proximity}
      #{place.scan(/.{1,73}/).join("\n ")}
      X-WR-ALARMUID:0A1B2C3D-0000-4000-8000-000000000001
      END:VALARM
      END:VTODO
      END:VCALENDAR
    ICS
  end

  # Each VALARM in the text, as its sorted, unfolded property lines.
  def unfolded_alarms(ics)
    ics.gsub(/\r?\n[ \t]/, "").scan(/^BEGIN:VALARM\r?\n(.*?)^END:VALARM/m).map { it.first.split(/\r?\n/).sort }
  end

  def location_alarm(ics) = unfolded_alarms(ics).find { |lines| lines.any? { it.start_with?("X-APPLE-PROXIMITY:") } }
  def time_alarm(ics) = unfolded_alarms(ics).find { |lines| lines.none? { it.start_with?("X-APPLE-PROXIMITY:") } }
end
