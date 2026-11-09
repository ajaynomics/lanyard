# How an agent wakes itself later: a prompt sent to its own thread on a
# schedule. Each run arrives as the person's own word, so a routine is a
# standing trusted instruction: a mail or a peer's message must never plant one
# unseen. The person approves every one, never "Always", even where the install
# approves everything, and can pause or delete it on the agent's page.
class Tool::AddRoutine < Tool
  description "Have yourself woken on a schedule with a prompt, when the person asks for something regular: a morning " \
    "briefing, a weekly check. The schedule is plain words, such as \"every weekday at 8am\" or \"every monday at 9:30\", " \
    "or cron, in your time zone, no more often than every 5 minutes. The prompt is what you will be sent, so write it " \
    "to yourself. The person approves it first."
  argument :schedule, :string, min_length: 1, max_length: 200
  argument :prompt, :string, min_length: 1, max_length: Routine::PROMPT_LIMIT
  asks :approval, even_approving_everything: true

  def call(schedule:, prompt:)
    routine = agent.routines.create!(schedule: schedule, prompt: prompt)
    { id: routine.id, schedule: routine.schedule, nextRun: routine.next_run_at.in_time_zone(agent.time_zone).iso8601 }
  end
end
