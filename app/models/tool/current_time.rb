class Tool::CurrentTime < Tool
  description "The current date and time where the person is."

  def call
    now = Time.current.in_time_zone(bot.time_zone)
    { now: now.iso8601, timeZone: bot.time_zone, weekday: now.strftime("%A") }
  end
end
