# icalendar 2.13 writes a zero duration as "P", which is not one (RFC 5545
# 3.3.6). Phones write an alarm at the time of an event or task as
# TRIGGER:PT0S, so every later save of such an item would be refused
# (Tool::Calendar). Delete this once the gem writes a zero duration itself.
Icalendar::Values::Duration.prepend(Module.new do
  def value_ical = value.to_h.except(:past).values.all?(&:zero?) ? "PT0S" : super
end)
