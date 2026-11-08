# Deletes a deleted agent's Sprites, one per conversation. A Sprite is made never
# to expire, so without this every deleted agent leaves its computers behind.
# The agent is gone by now: its owner and its ids say what to delete.
class ComputerRemovalJob < ApplicationJob
  retry_on DurableAssistants::PiDurable::Client::Error, wait: :polynomially_longer, attempts: 10

  def perform(user, agent_id, computer, durable_ids)
    access = Agent::Access.for(user.agents.new(id: agent_id))
    client = DurableAssistants::PiDurable::Client.new
    durable_ids.each do |id|
      client.remove_computer(access, id, computer: computer)
    rescue DurableAssistants::PiDurable::Client::Error => error
      raise unless error.status == 404 # the sidecar never knew this conversation
    end
  end
end
