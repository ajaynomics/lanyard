# Starts a Workflow: several helpers working in the background on a job the
# agent set out as steps. Offered with helpers (the `subagents` capability),
# since every step is one. It returns at once; the person sees each step on
# the call's line and may cancel the run, and the agent hears every answer in
# one message when it ends (Workflow::Run). A script calls it as any tool.
class Tool::RunWorkflow < Tool
  description "Start a workflow: helpers working in the background on a job you set out as steps. " \
    "kind \"fan_out\" gives every step's task to its own helper at once (at most 3 work at a time; the rest wait their turn) " \
    "and gathers their answers; \"pipeline\" runs the steps in order, each helper given the answer of the step before. " \
    "A helper sees only its task, the context and, in a pipeline, the answer before it, never this conversation, so each task must " \
    "stand on its own. The call returns at once; the person watches each step and may cancel the run, and every answer comes to " \
    "you in one message when the last step ends. A step may name the model its helper runs on, by its name as your settings " \
    "show it, and its thinking (off, minimal, low, medium, high, xhigh or max); left out, it runs on your own."
  argument :name, :string, min_length: 1, max_length: Workflow::NAME_LIMIT
  argument :kind, :string, enum: Workflow::KINDS
  argument :steps, :array, min_items: 1, max_items: Workflow::STEPS,
    items: { "type" => "object", "additionalProperties" => false, "required" => [ "task" ],
             "properties" => { "task" => { "type" => "string", "minLength" => 1, "maxLength" => Helper::TASK_LIMIT },
                               "model" => { "type" => "string", "minLength" => 1, "maxLength" => 200 },
                               "thinking" => { "type" => "string", "minLength" => 1, "maxLength" => 20 } } }
  argument :context, :string, required: false, max_length: Workflow::CONTEXT_LIMIT,
    description: "Facts from this conversation every step's helper needs."

  def call(name:, kind:, steps:, context: nil)
    # A helper has no helpers of its own (agent/subagent.mjs).
    raise Refusal, "A helper can't start a workflow; only the agent can." if invocation.helper
    run = conversation.workflows.create!(name: name, kind: kind, steps: chosen(steps), context: context).start(call_id: invocation.call_id)
    { run: run.id, steps: run.steps.size,
      status: "Started. The person can watch and cancel it; every answer comes to you in one message when it ends." }
  end

  private
    # Each step with the route and level its helper runs on, as the sidecar
    # would choose them for a `subagent` call; refused, by step, before any starts.
    def chosen(steps)
      steps.map.with_index(1) do |step, position|
        model, thinking = ModelCatalog.for_helper(conversation.agent, model: step["model"], thinking: step["thinking"])
        { "task" => step["task"], "model" => model, "thinking" => thinking }.compact
      rescue ModelCatalog::Unoffered => refusal
        raise Refusal, "Step #{position}: #{refusal.message}"
      end
    end
end
