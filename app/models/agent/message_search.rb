# The threads of one agent whose messages contain some words, newest first.
# The words are matched in Ruby, as Rails reads each message, not with SQL
# LIKE, so the search still works once content is stored encrypted. Each
# request reads one batch; #older is where the next one starts, a plain
# message id, so every request stays bounded and no message is out of reach.
# Tool output is left out: it is the computer's words, not the conversation's.
class Agent::MessageSearch
  BATCH = 500

  def initialize(agent, words, before: nil)
    @agent, @words, @before = agent, words.to_s.strip.downcase, Integer(before, exception: false)
  end

  def conversation_ids
    batch.select { it.content.to_s.downcase.include?(@words) }.map(&:conversation_id).uniq
  end

  # The oldest message this batch read, when older ones are left to read.
  def older = (batch.last.id if read.size > BATCH)

  private
    def batch = read.first(BATCH)

    def read
      @read ||= messages.order(id: :desc).limit(BATCH + 1).select(:id, :conversation_id, :content).to_a
    end

    def messages
      found = @agent.workspace.messages.where(conversation: @agent.conversations, role: %w[ user assistant ])
      @before ? found.where(id: ...@before) : found
    end
end
