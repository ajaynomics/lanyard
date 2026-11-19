# Words for the Helpers panel (helpers/_row, workflow/runs/_row).
module HelpersHelper
  STATUSES = { "running" => [ "Working", "working" ], "done" => [ "Finished", "connected" ],
               "failed" => [ "Stopped", "error" ], "cancelled" => [ "Cancelled", "off" ] }.freeze

  # Where a helper or a workflow's run stands, as a word and a colour (ui/status).
  def work_status(work)
    text, kind = STATUSES.fetch(work.state)
    render "ui/status", text: text, kind: kind
  end

  # What a helper runs on, as the agent's settings name it: "Claude Sonnet 5.5 ·
  # Subscription · Low thinking". Nil for one that never said, which ran on its
  # agent's own. Named without asking the sidecar, as the Usage page names it.
  def ran_on(model, level)
    return if model.blank?
    thinking = (level == "off" ? "No thinking" : "#{Agent::THINKING_LEVEL_NAMES[level]} thinking" if Agent::THINKING_LEVEL_NAMES.key?(level))
    [ ModelCatalog.plain_name(model), ModelCatalog::SOURCES[model.split("/").first], thinking ].compact.join(" · ")
  end

  # A finished helper's or step's answer as one plain line: its Markdown read as text, cut short.
  def answer_line(work)
    return "It finished without an answer." if work.answer.blank?
    Nokogiri::HTML5.fragment(markdown(work.answer.first(2_000))).text.squish.truncate(200).presence || "It finished without an answer."
  end

  # Where a workflow's run stands, in a line: its steps done and what works now, or how it ended. A pipeline's
  # result is its last step's answer; a fan-out's answers are many, so the thread has them.
  def run_progress(run)
    steps = run.steps.to_a
    case run.state
    when "running"
      working = steps.select(&:running?)
      now = (run.pipeline? && working.one?) ? "Now: step #{working.sole.position}, #{working.sole.task.squish.truncate(100)}" : ("#{working.size} working" if working.any?)
      [ "#{run.done_count} of #{pluralize(steps.size, "step")} done", now ].compact.join(" · ")
    when "done"
      run.pipeline? ? answer_line(steps.last) : "Every step finished. Their answers went to the thread."
    when "failed"
      stopped = steps.find(&:failed?)
      stopped ? "Step #{stopped.position} stopped: #{stopped.reason.presence || "it ended without an answer"}." : "It stopped."
    else
      done = run.done_count
      done.positive? ? "Before you cancelled it, #{pluralize(done, "step")} had finished." : "You cancelled it before any step finished."
    end
  end
end
