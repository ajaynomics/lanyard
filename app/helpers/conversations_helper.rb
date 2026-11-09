module ConversationsHelper
  # A turn's time, empty until thread_times writes it in the reader's own zone:
  # Rails knows only UTC.
  def message_time(message)
    tag.time class: "message__time", datetime: message.created_at.iso8601
  end

  # A list row's line of the newest words (Conversation.with_preview): a
  # skill as its name, a message from a channel as its sender's, a reply
  # without its tool markers, on one line.
  def message_preview(conversation)
    preview_of(conversation.has_attribute?(:preview) ? conversation[:preview].to_s : "")
  end

  # The row's line: what needs the person, why it stopped, what it is doing, else the newest words.
  def standing_line(conversation, standing)
    case standing
    when "needs_you" then conversation.waiting_for || message_preview(conversation)
    when "error" then "Couldn't finish: #{failure_text(conversation.failure)}"
    when "working" then conversation.current_tool ? "Using #{tool_label(conversation.current_tool)}…" : "Working…"
    when "stopped" then "Its computer is off"
    else message_preview(conversation)
    end
  end

  # The marker's words, for a pointer's tooltip and a screen reader.
  def standing_title(conversation, standing)
    case standing
    when "needs_you" then "Needs you: #{conversation.waiting_for || "waiting for your answer"}"
    when "error" then "Stopped by an error: #{failure_text(conversation.failure)}"
    when "unread" then "New reply"
    when "working" then conversation.current_tool ? "Working: using #{tool_label(conversation.current_tool)}" : "Working"
    when "stopped" then "Stopped: its computer is off"
    end
  end

  def preview_of(text)
    text = text.to_s.sub(Message::DOCUMENT_CHANGES, "")
    if (incoming = Message.new(role: "user", content: text).incoming)
      text = [ incoming.sender, incoming.body ].compact.join(": ")
    elsif (skill = text.match(Message::SKILL_BLOCK))
      text = [ "/skill:#{skill[1]}", skill[4] ].compact.join(" ")
    end
    text.gsub(Message::TOOL_MARKER, "").squish.truncate(140).presence || "No messages yet"
  end

  # What keeps the agent list still under the person's hand (sidebar_order_controller).
  # Rows sort by the last news for the person (Conversation::Standing) and change
  # in place at once; a move waits while the pointer, keyboard focus or a scroll
  # is on the list, then comes a second later, and the list moves at most every
  # two seconds. A click that ends on another row than it began on opens nothing.
  def sidebar_order_actions
    %w[ pointerenter->sidebar-order#hold pointerleave->sidebar-order#release focusin->sidebar-order#hold focusout->sidebar-order#release
        scroll->sidebar-order#scrolled pointerdown->sidebar-order#press click->sidebar-order#guard ].join(" ")
  end
end
