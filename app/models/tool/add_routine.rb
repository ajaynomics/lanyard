# How an agent wakes itself later: a prompt sent to its own thread on a
# schedule, or once at a time. Each run arrives as the person's own word, so a
# routine is a standing trusted instruction, a one-off as much as any: a mail
# or a peer's message must never plant one unseen. The person approves every
# one, never "Always", even where the install approves everything, unless the
# install names its workspace as needing no card for them
# (APP__ROUTINES_UNASKED_WORKSPACES); either way they can pause or delete it on
# the agent's page.
class Tool::AddRoutine < Tool
  description "Have yourself woken with a prompt: on a schedule when the person asks for something regular (a morning " \
    "briefing, a weekly check), or once at a time (\"remind me Thursday at 3\"). Give exactly one of schedule or at. " \
    "The prompt is what you will be sent, so write it to yourself. The person approves it first."
  # Exactly one of the two: providers refuse oneOf at a schema's top level, so
  # the descriptions say it and #refusal holds it.
  argument :schedule, :string, required: false, min_length: 1, max_length: 200,
    description: "To repeat: plain words, such as \"every weekday at 8am\" or \"every monday at 9:30\", or cron, in your " \
      "time zone, no more often than every 5 minutes. Not with at."
  argument :at, :string, required: false, max_length: 40, pattern: "^\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d",
    description: "To run once: a date and time in your time zone, as YYYY-MM-DDTHH:MM (an offset, if given, is kept), " \
      "in the future. Not with schedule."
  argument :prompt, :string, min_length: 1, max_length: Routine::PROMPT_LIMIT
  asks :approval, even_approving_everything: true
  sets_routines

  def refusal
    given = arguments.slice("schedule", "at").compact_blank.keys
    return "Give exactly one of schedule (to repeat) or at (once), not #{given.none? ? "neither" : "both"}." unless given.one?
    return unless given == [ "at" ]
    at = arguments["at"]
    time = Routine.local_time(at, agent.time_zone)
    return "I can't read #{at} as a date and time; give one as YYYY-MM-DDTHH:MM." unless time
    "#{at} has already passed: it is now #{Time.current.in_time_zone(time.time_zone).strftime("%Y-%m-%d %H:%M")} in your time zone. " \
      "Give a time in the future." unless time.future?
  end

  # A one-off's card says when, in words, and in which zone.
  def approval_title(arguments)
    time = Routine.local_time(arguments["at"], agent.time_zone) if arguments["schedule"].blank?
    "Wake #{agent.name} once, #{Routine.in_words(time)}?" if time
  end

  def approval_note(arguments)
    "In #{agent.name}'s time zone, #{agent.time_zone}. It runs once, then is gone." if arguments["at"].present?
  end

  def call(prompt:, schedule: nil, at: nil)
    routine = agent.routines.create!(schedule: schedule, once_at: at && Routine.local_time(at, agent.time_zone), prompt: prompt)
    { id: routine.id, schedule: routine.in_words, nextRun: routine.next_run_at.in_time_zone(agent.time_zone).iso8601 }
  end
end
