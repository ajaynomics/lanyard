# What the four concourse_ tools share (docs/design/PARITY.md §27): the bot's
# Concourse client, and Concourse's problems as refusals the model reads.
# Bot#tools offers the tools only when the bot has a ConcourseAgent.
module Tool::ConcourseCalls
  def permitted? = bot.concourse_agent.present?

  private
    def concourse
      bot.concourse_agent&.client or raise Tool::Refusal, "#{bot} is not on Concourse."
    end

    def on_concourse
      yield
    rescue DurableAssistants::Concourse::Client::Error => problem
      raise Tool::Refusal, problem.message
    end

    # A task this agent may act on: one linked to this conversation.
    def linked_task(task_id, direction: nil)
      tasks = direction ? conversation.peer_tasks.where(direction: direction) : conversation.peer_tasks
      tasks.find_by(task_id: task_id) or
        raise Tool::Refusal, "Task #{task_id} is not one #{direction == "inbound" ? "a peer sent this agent" : "this agent sent or received"}."
    end
end
