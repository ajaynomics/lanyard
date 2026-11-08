# A page of an agent's thread: its newest SIZE turns, or the ones before an
# entry, with the ledger calls and tool results they show looked up once for
# the page. A thread grows for as long as the agent lives, so the page shows
# the newest and earlier pages load as the person scrolls up.
#
# A turn is a person's message, a reply or a summary; a tool result comes with
# the reply that called it. So a page never starts at a result, and a call and
# its result are never on different pages.
class Conversation::Page
  SIZE = 40

  attr_reader :conversation, :before

  def initialize(conversation, before: nil)
    @conversation = conversation
    @before = before
  end

  def messages
    @messages ||= begin
      scope = shown.includes(conversation: :agent).with_attached_images
      (start ? scope.where(entry_id: start..) : scope).to_a
    end
  end

  # The entry the next page up ends before; nil at the start of the thread.
  def earlier
    first = messages.first&.entry_id
    first if first && shown.where(entry_id: ...first).exists?
  end

  # Ledger rows by call id: the page's calls, the results it shows and the
  # calls a script or a helper made inside one of them.
  def invocations
    @invocations ||= conversation.invocations.includes(:approval, :answer)
      .where("substr(call_id, 1, instr(call_id || '/', '/') - 1) IN (?)", call_ids).index_by(&:call_id)
  end

  def results = @results ||= messages.select { it.role == "toolResult" }.index_by(&:tool_call_id)

  # The calls the page's replies made, where their results show.
  def placed = @placed ||= messages.flat_map { it.tool_calls.pluck("id") }.to_set

  private
    def shown
      scope = conversation.messages.shown
      before ? scope.where(entry_id: ...before) : scope
    end

    def start
      @start ||= shown.where.not(role: "toolResult").reorder(entry_id: :desc).offset(SIZE - 1).pick(:entry_id)
    end

    def call_ids = placed.to_a + results.keys.compact
end
