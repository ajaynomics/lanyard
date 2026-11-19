# An agent's thread as a small screen reads it (the Watch, #78): the person's
# messages and the agent's replies, newest SIZE of them, each as plain words.
# Never a tool's result, a call's arguments or a link's address. Earlier turns
# come a page at a time, before the entry the last page started at. Reading
# it is not opening the thread: it stays unread.
class Conversation::Transcript
  SIZE = 20
  ROLES = %w[ user assistant ].freeze

  attr_reader :conversation, :before

  def initialize(conversation, before: nil)
    @conversation = conversation
    @before = before
  end

  def as_json(*)
    { conversation_id: conversation.id, agent: conversation.agent.to_s, messages: messages, earlier: earlier }
  end

  # The entry the next page up ends before; nil at the start of the thread.
  def earlier
    first = page.first&.entry_id
    first if first && turns.where(entry_id: ...first).exists?
  end

  private
    def messages
      page.filter_map do |message|
        text = Message.plain_text(message.content)
        { id: message.id, role: message.role, text: text, at: message.created_at.iso8601 } if text.present?
      end
    end

    def page = @page ||= turns.reorder(entry_id: :desc, id: :desc).limit(SIZE).to_a.reverse

    def turns
      scope = conversation.messages.where(role: ROLES)
      before ? scope.where(entry_id: ...before) : scope
    end
end
