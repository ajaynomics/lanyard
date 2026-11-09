# What the four concourse_ tools share: the agent's
# Concourse client, and Concourse's problems as refusals the model reads.
# Agent#tools offers the tools only when the agent's ConcourseAgent is
# admitted: one waiting for approval can read and send nothing yet.
module Tool::ConcourseCalls
  def permitted? = agent.concourse_agent&.admitted? || false

  private
    def concourse
      agent.concourse_agent&.client or raise Tool::Refusal, "#{agent} is not on Concourse."
    end

    def on_concourse
      yield
    rescue DurableAssistants::Concourse::Client::Error => problem
      raise Tool::Refusal, problem.message
    end

    # A task this conversation may act on: one linked to it.
    def linked_task(task_id, direction: nil)
      tasks = direction ? conversation.peer_tasks.where(direction: direction) : conversation.peer_tasks
      tasks.find_by(task_id: task_id) or
        raise Tool::Refusal, "Task #{task_id} is not one #{direction == "inbound" ? "a peer sent this agent" : "this agent sent or received"}."
    end
end
