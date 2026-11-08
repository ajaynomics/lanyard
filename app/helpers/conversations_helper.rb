module ConversationsHelper
  # A list row's line of the newest words (Conversation.with_preview): a
  # skill as its name, a reply without its tool markers, on one line.
  def message_preview(conversation)
    text = conversation.has_attribute?(:preview) ? conversation[:preview].to_s : ""
    if (skill = text.match(Message::SKILL_BLOCK))
      text = [ "/skill:#{skill[1]}", skill[4] ].compact.join(" ")
    end
    text.gsub(/\[tool: [\w-]+\]/, "").squish.truncate(140).presence || "No messages yet"
  end
end
