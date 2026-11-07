# What the four concourse_ tools share (docs/design/PARITY.md §27): the agent's
# Concourse client, and Concourse's problems as refusals the model reads.
# Agent#tools offers the tools only when the agent has a ConcourseAgent.
module Tool::ConcourseCalls
  def permitted? = agent.concourse_agent.present?

  private
    def concourse
      agent.concourse_agent&.client or raise Tool::Refusal, "#{agent} is not on Concourse."
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
