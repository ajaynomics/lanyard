# The ledger itself holds an uncertain create. Record the reservation before
# leaving SQLite so a crash between the send and its reply cannot reopen it.
class Invocation::ForgeWrite
  UNRESOLVED = { "forge_write" => "unresolved" }.freeze
  HELD = "An earlier forge write is unresolved. Have the workspace owner check it before trying again."
  UNKNOWN = "The forge write outcome is unknown. It is held and will not be retried."
  RESOLUTIONS = %w[ applied not_applied ].freeze

  def initialize(invocation)
    @invocation = invocation
  end

  def blocked?
    ledger.where("json_extract(invocations.result, '$.forge_write') = ?", UNRESOLVED.fetch("forge_write"))
      .find_each.any? { |earlier| earlier.call_arguments.values_at("repo", "branch") == target }
  end

  def reserve!
    @invocation.with_lock do
      raise Tool::Refusal, Tool::Forge::UNAVAILABLE unless @invocation.running? && @invocation.started_at?
      raise Tool::Refusal, HELD if blocked?
      @invocation.update!(result: UNRESOLVED)
    end
  end

  def confirm!(result)
    @invocation.with_lock do
      raise Tool::Refusal, UNKNOWN unless @invocation.running? && @invocation.result == UNRESOLVED &&
        !receipt_used?(result.fetch("receipt_id"))
      # Checking uniqueness and settling the call share SQLite's write lock.
      @invocation.update!(state: :succeeded, result: result)
    end
    result
  end

  def resolve!(resolution, by:)
    raise ArgumentError, "Choose applied or not_applied." unless resolution.in?(RESOLUTIONS)
    @invocation.with_lock do
      raise Invocation::NotTheApprover unless by&.persisted? && by == @invocation.workspace.owner
      raise Invocation::Conflict unless @invocation.call_name == "forge" && @invocation.failed? && @invocation.result == UNRESOLVED
      @invocation.update!(result: { "forge_write" => resolution, "resolved_by_id" => by.id },
        error: resolution == "applied" ? "The workspace owner confirmed the forge write was applied." :
          "The workspace owner confirmed the forge write was not applied.")
    end
  end

  private
    def target = @invocation.call_arguments.values_at("repo", "branch")

    def receipt_used?(id)
      ledger.succeeded.where("json_extract(invocations.result, '$.receipt_id') = ?", id).exists?
    end

    def ledger
      calls = @invocation.workspace.invocations
      calls.where(tool_name: "forge").or(calls.where(tool_name: "use_tool").where("json_extract(invocations.arguments, '$.name') = ?", "forge"))
    end
end
