class Tool::ListRoutines < Tool
  description "List your routines: the prompts you are sent on a schedule or once, and when each runs next."
  def call
    { routines: agent.routines.order(:id).map { |routine|
      { id: routine.id, schedule: routine.in_words, prompt: routine.prompt, paused: routine.paused?,
        nextRun: routine.next_run_at&.in_time_zone(agent.time_zone)&.iso8601 } } }
  end
end
