module ConversationsHelper
  # A list row's line of the newest words (Conversation.with_preview): a
  # skill as its name, a message from a channel as its sender's, a reply
  # without its tool markers, on one line.
  def message_preview(conversation)
    preview_of(conversation.has_attribute?(:preview) ? conversation[:preview].to_s : "")
  end

  def preview_of(text)
    text = text.to_s.sub(Message::DOCUMENT_CHANGES, "")
    if (incoming = Message.new(role: "user", content: text).incoming)
      text = [ incoming.sender, incoming.body ].compact.join(": ")
    elsif (skill = text.match(Message::SKILL_BLOCK))
      text = [ "/skill:#{skill[1]}", skill[4] ].compact.join(" ")
    end
    text.gsub(/\[tool: [\w-]+\]/, "").squish.truncate(140).presence || "No messages yet"
  end
end
