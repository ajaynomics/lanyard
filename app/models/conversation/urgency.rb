# Whether a message from someone (Concourse mail, an email, a text, Campfire,
# Telegram) goes in at the agent's next step, or waits in its inbox until the
# agent finishes or takes it in sooner (Tool::WaitingMessages, #85). One rule
# for every channel (Conversation#receive), plain, never a model: it comes
# from the agent's own person, its sender marked it urgent, or its words open
# with "urgent", "stop" or "asap". Steering changes only when the agent
# reads it, never what it may do: it is still someone else's words.
class Conversation::Urgency
  # "URGENT: …", "Stop, wrong city", "**Urgent** …", and after a mention
  # of the bot, as a group post to it starts: "@desk_bot asap, …".
  OPENING = /\A(?:[^[:alnum:]@]*@\w+)*[^[:alnum:]]*(?:urgent|stop|asap)\b/i

  def self.when_busy(*openings, marked: false, from_person: false)
    urgent?(*openings, marked: marked, from_person: from_person) ? "steer" : "followUp"
  end

  def self.urgent?(*openings, marked: false, from_person: false)
    marked || from_person || openings.any? { it.to_s.match?(OPENING) }
  end
end
