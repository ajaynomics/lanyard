# What the four concourse_ tools share: which of the agent's Concourse
# identities a call goes through, and Concourse's problems as refusals the
# model reads. Agent#tools offers the tools only while at least one identity
# is admitted: one waiting for approval can read and send nothing yet.
#
# An agent may be in several organizations (networks), each its own trust
# boundary. A task is answered on the network it came or went on, whatever
# the call says; a new task names its network once there are two, since a
# wrong guess would send work across that boundary.
module Tool::ConcourseCalls
  def permitted? = agent.concourse_networks.any?

  private
    # The identity for new work: the one named, or the only one.
    def network(name)
      networks = agent.concourse_networks
      names = networks.map(&:organization).to_sentence(two_words_connector: " or ", last_word_connector: " or ")
      if name.present?
        networks.find { it.organization == name } or raise Tool::Refusal, "#{agent} is not on network #{name}. Its networks: #{names}."
      elsif networks.one?
        networks.sole
      elsif networks.none?
        raise Tool::Refusal, "#{agent} is not on Concourse."
      else
        raise Tool::Refusal, "#{agent} is on more than one network. Name the network: #{names}."
      end
    end

    # The identity a task came or went on, while it is still connected.
    def network_of(peer_task)
      channel = peer_task.channel
      return channel if channel&.admitted?
      raise Tool::Refusal, "Task #{peer_task.task_id} came on #{channel ? "network #{channel.organization}, where #{agent} is not connected now" : "a network #{agent} has left"}."
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
