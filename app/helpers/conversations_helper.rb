module ConversationsHelper
  # The sidebar's least and most width, in rem, as its edge is dragged
  # (sidebar_resize_controller.js); layout.css holds it between them too.
  def sidebar_widths = 14..28

  # The width the person dragged the sidebar to, from its cookie, so the page
  # is drawn at it rather than jumping to it once the script runs.
  def sidebar_width_style
    width = cookies[:sidebar_width].to_s
    "--sidebar-width: #{width.to_i}px" if width.match?(/\A\d{2,4}\z/)
  end

  # Only the ids of branches in the rendered tree can affect its open state.
  def collapsed_agent_groups
    value = cookies[:collapsed_agents].to_s
    value.bytesize <= 1_919 ? value.split("|").first(96).select { it.match?(/\A[1-9]\d{0,18}\z/) }.to_set : Set.new
  end

  # When a row last changed, short enough that the name keeps the room: "now",
  # "4m", "3h" today, "Tue" this week, "Nov 4" this year, "11/4/25" before.
  # local_time_controller.js keeps the same rules in the reader's own zone and
  # moves them on; this is what shows before it runs, and after a broadcast
  # row is morphed in. The full time is in its title.
  def list_time(at, now: Time.current)
    ago = now - at
    days = (now.to_date - at.to_date).to_i
    if ago < 1.minute then "now"
    elsif ago < 1.hour then "#{(ago / 1.minute).floor}m"
    elsif days.zero? then "#{(ago / 1.hour).floor}h"
    elsif days < 7 then at.strftime("%a")
    elsif at.year == now.year then at.strftime("%b %-d")
    else at.strftime("%-m/%-d/%y")
    end
  end

  # A turn's time, empty until thread_times writes it in the reader's own zone:
  # Rails knows only UTC.
  def message_time(message)
    tag.time class: "message__time", datetime: message.created_at.iso8601
  end

  # A list row's line of the newest words (Conversation.with_preview): a
  # skill as its name, an outside message with its sender, a reply without
  # its tool markers, on one line.
  def message_preview(conversation)
    preview_of(conversation.has_attribute?(:preview) ? conversation[:preview].to_s : "")
  end

  # The row's line: what needs the person, why it stopped, what it is doing, else the newest words.
  def standing_line(conversation, standing)
    case standing
    when "needs_you" then conversation.waiting_for || message_preview(conversation)
    when "error" then "Couldn't finish: #{failure_text(conversation.failure)}"
    when "working" then conversation.current_tool ? "Using #{tool_label(conversation.current_tool)}…" : "Working…"
    when "unknown" then "Checking run status"
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
    when "unknown" then "Checking run status"
    when "stopped" then "Stopped: its computer is off"
    end
  end

  def preview_of(text)
    text = text.to_s.sub(Message::DOCUMENT_CHANGES, "")
    if (incoming = Message.new(role: "user", content: text).incoming)
      text = incoming.trusted ? incoming.body : [ incoming.sender, incoming.body ].compact.join(": ")
    elsif (skill = text.match(Message::SKILL_BLOCK))
      text = [ "/skill:#{skill[1]}", skill[4] ].compact.join(" ")
    end
    # Undo the extra escaping of entities without turning them into Markdown syntax.
    text = text.gsub(Message::TOOL_MARKER, "").gsub(/&amp;(?=(?:[a-z][a-z0-9]*|#\d+|#x[0-9a-f]+);)/i, "&")
    plain = Message.plain_text(text.encode(Encoding::UTF_8)) unless text.blank?
    plain&.truncate(140).presence || "No messages yet"
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
