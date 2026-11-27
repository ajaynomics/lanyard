# Sends a message to another agent on Concourse. It leaves this app, so the
# person allows each send first. The A2A messageId names this exact call, and
# each send is recorded (Dispatch) before Concourse is asked: Concourse can
# take a message and give no answer in time, and a call that only
# remembered its answer would not know whether it sent. Such a send is
# looked up by its messageId in Concourse's receipts until it is known.
class Tool::ConcourseSend < Tool
  prepend Tool::AsksEverySend
  include Tool::ConcourseCalls
  include Tool::ConcourseDestination

  SENT = "Sent. The answer will come to you as a new message.".freeze
  # Concourse took the message but never answered, and has no receipt for it
  # yet. Not a failure, which an agent would send again.
  UNCONFIRMED = "Unknown: Concourse didn't answer in time and has no receipt for this message yet, so it may have gone. " \
    "Don't send it again: it is being checked, and you'll be told here whether it went.".freeze

  description "Send a message to another agent on Concourse, the agents' mail network. Its answer comes back to you later, as a new message. " \
    "To add to a task you sent earlier, give its task_id; it goes on that task's network."
  argument :to, :string, description: "The agent's address, prefix/agent, as concourse_find lists it.", pattern: "^[A-Za-z0-9_-]{1,100}/[A-Za-z0-9_-]{1,100}$"
  argument :text, :string, min_length: 1, max_length: 64_000
  argument :task_id, :string, required: false, description: "A task you sent earlier, to continue it.", pattern: "^[A-Za-z0-9_.:-]{1,512}$"
  argument :network, :string, required: false, pattern: "^[A-Za-z0-9_-]{1,100}$",
    description: "For a new task, the network (organization) to send it on. Needed only when you are in more than one."
  asks :approval
  reaches_others
  effect :external
  safe_to_repeat

  def recipients = [ arguments["to"].to_s ]

  # Onto a bridge, outside the workspace's home network, every send asks a
  # person, whatever "Always" or the install says: words from one network
  # reach another only in a message a person allowed, which the ledger keeps
  # (docs/design/workspaces.md, 3).
  def always? = !onto_bridge? && super
  def every_time? = onto_bridge? || super
  def even_approving_everything? = onto_bridge? || super

  # A send on a network the install names inside (APP__INSIDE_CONCOURSE_NETWORKS)
  # reaches only its own agents, so under "Ask before what reaches other people"
  # it doesn't ask. A bridge is never inside.
  def reaches_outsiders? = !inside_network?

  # A guarded send has its destination resolved before the card can be answered.
  def refusal
    if asks_every_send?
      earlier, channel = delivery_route(arguments["to"], arguments["task_id"], arguments["network"])
      review_destination(channel, arguments["to"], earlier)
    elsif !arguments["task_id"]
      network(arguments["network"])
    end
    nil
  rescue Refusal => problem
    problem.message
  end

  def call(to:, text:, task_id: nil, network: nil)
    earlier, channel = delivery_route(to, task_id, network)
    verify_destination(channel, to, earlier)
    fingerprint = Dispatch.fingerprint(self.class.tool_name, channel.organization, to, task_id, text)
    refuse_repeat(to, fingerprint)
    # Recorded before Concourse is asked; a call that has one already was tried, and never sends again.
    dispatch = Dispatch.record(invocation, tool_name: self.class.tool_name, sender: channel.organization, fingerprint: fingerprint) or
      return tried(invocation.reload_dispatch, to)
    result = channel.client.send_message(to, message_id: self.class.message_id(invocation), text: text, task_id: task_id, context_id: earlier&.context_id)
    unless result["status"]
      dispatch.confirm(self.class.message_id(invocation))
      return { delivered: true, answer: PeerTask.text_of(result) }
    end
    dispatch.confirm(self.class.link(conversation, channel, to, result).task_id)
    tried(dispatch, to)
  rescue DurableAssistants::Concourse::Client::Error => problem
    if dispatch && problem.uncertain?
      dispatch.checking!
      tried(dispatch, to)
    else
      # Refused, or never reached: nothing went.
      dispatch&.refused
      raise Refusal, problem.message
    end
  end

  # Concourse's id for the message a dispatch recorded, from its receipt
  # (Dispatch#check): its task, linked to the conversation so the answer
  # reaches the agent, or the messageId of one answered directly. Nil while
  # Concourse has no receipt for it.
  def self.find_dispatched(dispatch)
    channel = dispatch.agent.concourse_networks.find { it.organization == dispatch.sender } or
      raise Dispatch::LookupFailed, "#{dispatch.agent} is no longer on network #{dispatch.sender}."
    arguments = dispatch.invocation.call_arguments
    receipt = channel.client.receipt(message_id(dispatch.invocation), recipient: arguments["to"], task_id: arguments["task_id"])
    return unless receipt["accepted"] == true
    return message_id(dispatch.invocation) unless receipt["taskId"].is_a?(String)
    link(dispatch.conversation, channel, arguments["to"], channel.client.task(receipt["taskId"])).task_id
  rescue DurableAssistants::Concourse::Client::Error => error
    raise Dispatch::LookupFailed, error.message
  end

  def self.dispatch_words(arguments)
    Dispatch::Words.new(noun: "Concourse message", to: arguments["to"], excerpt: arguments["text"].to_s, provider: "Concourse",
      log: "Concourse's website, or with #{arguments["to"]}'s owner")
  end

  # Unique to this call of this agent: the sidecar's task and call ids are
  # only unique within one conversation.
  def self.message_id(invocation) = "durable-assistants:#{invocation.conversation.durable_id}:#{invocation.task_id}:#{invocation.call_id}"

  # The task a send made, or continued, linked to its conversation, so the
  # answer comes back to it.
  def self.link(conversation, channel, to, task)
    peer_task = conversation.peer_tasks.create_or_find_by!(task_id: task["id"]) do
      it.direction = "outbound"
      it.peer = to
      it.context_id = task["contextId"]
      it.state = task.dig("status", "state")
      it.concourse_agent = channel
    end
    peer_task.tap { it.update!(state: task.dig("status", "state")) }
  end

  private
    def delivery_route(to, task_id, name)
      earlier = linked_task(task_id, direction: "outbound") if task_id
      raise Refusal, "Task #{task_id} was sent to #{earlier.peer}, not #{to}." if earlier && earlier.peer != to
      [ earlier, earlier ? network_of(earlier) : network(name) ]
    end

    # On a network the install names inside, and not across a bridge.
    def inside_network?
      channel = sending_channel
      channel.present? && !channel.bridge? && channel.organization.in?(DurableAssistants.config(:app, :inside_concourse_networks, default: []))
    end

    def onto_bridge? = sending_channel&.bridge? || false

    # The network this call goes on, or nil where it names none it can use.
    def sending_channel
      task_id = arguments["task_id"]
      task_id ? conversation.peer_tasks.outbound.find_by(task_id: task_id)&.channel : network(arguments["network"])
    rescue Refusal
      nil
    end

    # What the call answers for a message it tried: sent, with its task, or
    # not known yet, with the key it is checked under. One not known yet is
    # looked up once more first: a replay may find its receipt.
    def tried(dispatch, to)
      raise Refusal, "This message to #{to} was not sent." if dispatch.not_sent?
      dispatch.look_up unless dispatch.settled?
      if dispatch.sent?
        peer_task = conversation.peer_tasks.find_by(task_id: dispatch.provider_id)
        return { sent: to, network: dispatch.sender, note: "It went, so it wasn't sent again." } unless peer_task
        { taskId: peer_task.task_id, state: peer_task.state, network: dispatch.sender, note: SENT }
      else
        { unknown: to, network: dispatch.sender, key: dispatch.key, note: UNCONFIRMED }
      end
    end

    # The same words to the same agent on the same task, just sent, still
    # being checked or still unknown: the agent retrying a message that
    # went, or may have.
    def refuse_repeat(to, fingerprint)
      earlier = agent.dispatches.repeated(fingerprint, by: invocation) or return
      at = Conversation.stamp(earlier.created_at, agent.time_zone)
      if earlier.sent?
        raise Refusal, "This same message went to #{to} at #{at}#{" (Concourse id #{earlier.provider_id})" if earlier.provider_id}, so it wasn't sent again."
      elsif earlier.unknown?
        raise Refusal, "This same message to #{to}, sent at #{at}, may have gone and whether it did is still unknown (key #{earlier.key}), " \
          "so it wasn't sent again. Ask your person to check and say on its card whether it went."
      else
        raise Refusal, "This same message to #{to}, sent at #{at}, may have gone and is still being checked (key #{earlier.key}), " \
          "so it wasn't sent again. You'll be told here whether it went."
      end
    end
end
