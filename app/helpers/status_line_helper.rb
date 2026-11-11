# The status line's words (conversations/_status_line, Conversation::StatusLine).
module StatusLineHelper
  # "Medium effort", or "No thinking".
  def effort_words(effort) = effort == "Off" ? "No thinking" : "#{effort} effort"

  # "Included in plan" on a subscription; "$2.14 this thread" on an API key.
  def billing_words(status)
    if status.subscription? then "Included in plan"
    elsif status.cost then "#{number_to_currency(status.cost)} this thread"
    end
  end

  def cost_words(status)
    price = number_to_currency(status.cost) if status.cost
    if status.subscription?
      safe_join([ "Included in plan", (tag.span(" (would be #{price} at API prices)", class: "status-line__aside") if price) ].compact)
    elsif price
      "#{price} at API prices, an estimate"
    end
  end

  # "42% · 84k of 200k tokens"
  def room_words(status)
    return "Summarised; measured after the next reply" if status.summarised?
    return "Measured after the first reply" unless (tokens = status.context_tokens)
    size = status.context_window || status.compact_at
    size ? "#{percent(tokens.fdiv(size))} · #{thousands(tokens)} of #{thousands(size)} tokens" : "#{thousands(tokens)} tokens"
  end

  # On more than one network, a network not connected is named.
  def concourse_words(concourse_agent, named: false)
    words = if concourse_agent.connected? then "Concourse connected"
    elsif concourse_agent.awaiting_approval? then "Concourse: waiting for approval"
    elsif concourse_agent.declined? then "Concourse declined this agent"
    else "Concourse offline: mail can't arrive"
    end
    named && !concourse_agent.connected? ? "#{words} in #{concourse_agent.organization}" : words
  end

  # A network's state on the Channels page, and its colour: Not joined with none.
  def concourse_status(concourse_agent)
    if concourse_agent.nil? then [ "Not joined", "off" ]
    elsif concourse_agent.awaiting_approval? then [ "Waiting for approval", "attention" ]
    elsif concourse_agent.declined? then [ "Declined", "error" ]
    elsif concourse_agent.disconnected? then [ "Disconnected", "error" ]
    elsif concourse_agent.check_error then [ "Error", "error" ]
    else [ "Connected", "connected" ]
    end
  end

  # ok, wait or trouble: the dot's colour.
  def concourse_state(status)
    if status.concourse_trouble? then "trouble"
    elsif status.concourse_agent.awaiting_approval? then "wait"
    else "ok"
    end
  end

  # "2 open tasks waiting on others, 1 on this agent"
  def open_tasks_words(tasks)
    counts = tasks.group(:direction).count
    others, mine = counts["outbound"].to_i, counts["inbound"].to_i
    return "no open tasks" if (others + mine).zero?
    [ ("#{pluralize(others, "open task")} waiting on others" if others.positive?),
      ("#{pluralize(mine, "open task")} waiting on this agent" if mine.positive?) ].compact.join(", ")
  end
end
