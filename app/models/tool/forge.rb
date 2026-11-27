class Tool::Forge < Tool
  UNAVAILABLE = "The forge binding is not available for this call."
  FILES_UNAVAILABLE = "Forge file delivery is not available yet."
  BUSY = "Another forge call is already in progress."
  UNKNOWN = "The forge bridge did not confirm a bounded result."

  description "Read pull request metadata (number), a diff (base and head), CI runs (head_sha) or CI jobs (run_id) in a configured repo. " \
    "Fetch, CI logs, CI artifacts and push are not available yet."
  argument :verb, :string, enum: Wire::VERBS.keys
  argument :repo, :string, max_length: 160, description: "An exact configured owner/repository."
  argument :number, :integer, required: false, minimum: 1, maximum: Wire::NUMBER.end
  %i[ ref base head ].each { |name| argument name, :string, required: false, max_length: 200 }
  %i[ head_sha revision ].each { |name| argument name, :string, required: false, pattern: "^[0-9a-f]{40}$" }
  %i[ run_id job_id ].each { |name| argument name, :integer, required: false, minimum: 1, maximum: Wire::ID.end }
  argument :name, :string, required: false, pattern: "^[A-Za-z0-9._-]{1,100}$"
  argument :max_bytes, :integer, required: false, minimum: 1, maximum: Wire::PATCH_LIMIT
  argument :tail, :boolean, required: false
  argument :have, :array, required: false, max_items: 32, items: { type: "string", pattern: "^[0-9a-f]{40}$" }
  argument :branch, :string, required: false, max_length: 324
  argument :expected_head, :string, required: false, pattern: "^(?:absent|(?!0{40}$)[0-9a-f]{40})$"
  effect :external

  def self.start_once? = true
  def self.available_to?(agent) = Binding.for(agent).present?
  def self.request?(tool, arguments) = tool == tool_name || (tool == "use_tool" && arguments["name"] == tool_name)

  def self.admits?(conversation, tool, arguments)
    if tool == "use_tool"
      return false unless arguments.keys.to_set == Set["name", "arguments"]
      arguments = arguments["arguments"]
    end
    agent = conversation.agent
    Binding.for(agent)&.allows?(arguments) && authorized?(agent) &&
      conversation.tool(tool_name) == self && errors_for(arguments).empty?
  end

  def self.authorized?(agent) = !agent.paused? && agent.workspace.member?(agent.user)

  def permitted? = Binding.for(agent)&.allows?(arguments) && self.class.authorized?(agent)

  def refusal
    return FILES_UNAVAILABLE if Wire::VERBS.fetch(arguments["verb"]).delivery == :workspace
    # Invocation checks this under its SQLite write transaction before claiming the job.
    BUSY if agent.conversations.joins(:invocations).merge(Invocation.running.where.not(id: invocation.id))
      .where("invocations.tool_name = 'forge' OR (invocations.tool_name = 'use_tool' AND json_extract(invocations.arguments, '$.name') = 'forge')").exists?
  end

  def call(**input)
    binding = Binding.for(agent)
    operation = arguments
    raise Refusal, UNAVAILABLE unless binding&.allows?(operation) && input == operation.symbolize_keys &&
      self.class.authorized?(agent) && invocation.forge_live?
    verb = Wire::VERBS.fetch(operation["verb"])
    raise Refusal, FILES_UNAVAILABLE if verb.delivery == :workspace

    exchange(binding.socket_path, operation, verb)
  end

  private
    def exchange(socket_path, operation, verb)
      reply, frame = DurableAssistants::ForgeTransport.call(socket_path, context: context, operation: operation,
        timeout: verb.timeout, reply_frame_limit: verb.reply_frame)
      if Wire.failure?(operation, reply)
        raise Refusal, "The forge bridge did not complete this read (#{reply.fetch('reason')})."
      end
      ReadResult.confirmed(operation, reply, frame) || raise(Refusal, UNKNOWN)
    rescue Refusal
      raise
    rescue StandardError
      # Neither the bridge's exception nor its cause belongs in the tool result.
      raise Refusal, UNKNOWN, cause: nil
    end

    def context
      { agent_id: conversation.agent_id, workspace_id: agent.workspace_id, conversation_id: conversation.id,
        invocation_id: invocation.id, task_id: invocation.task_id, call_id: invocation.call_id }
    end
end
