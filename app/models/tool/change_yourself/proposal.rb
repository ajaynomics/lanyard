class Tool::ChangeYourself
  # A change bound to the saved text and revision it was proposed against. The
  # card shows it, a person allows it and the call saves it only while those
  # still hold, so an allowed card never saves over a newer edit.
  class Proposal
    KEY = "instruction_change"
    STALE = "The target or its instructions changed, or this proposal is no longer available. Ask the agent to read the current instructions and propose a new change."
    # A nudge, not a limit: history keeps every version, so nothing is refused for its size.
    WARN_AT = 12_000
    WARNING = "These instructions exceed 12,000 characters. Try deleting one line for each line you add."

    def initialize(invocation)
      @invocation = invocation
      @agent = invocation.agent
      @workspace = @agent.workspace
      @arguments = invocation.call_arguments
      @target = workspace? ? @workspace : @agent
      @before = @target.instructions
    end

    # History moves with an agent. Keep fingerprints, not another copy of the
    # source text or a diff that a different workspace could later read.
    def snapshot
      { "base" => base, "result_digest" => digest(result), "call_digest" => @invocation.digest }
    end

    def check!
      saved = @invocation.preview&.dig(KEY)
      raise Tool::Refusal, STALE unless saved && available? && saved["base"] == base && saved["call_digest"] == @invocation.digest

      result.tap { |text| raise Tool::Refusal, STALE unless saved["result_digest"] == digest(text) }
    end

    def current?
      check!
      true
    rescue Tool::Refusal
      false
    end

    def details
      after = check!
      InstructionsChange.new(@before, after).details.merge("warning" => warning(after)).compact
    rescue Tool::Refusal
      {}
    end

    def approvable_by?(person)
      workspace? ? person.present? && @workspace.owner == person : @workspace.member?(person)
    end

    def apply!(approval:)
      text = check!
      by = approval&.decided_by
      if (approval || workspace?) && !approvable_by?(by)
        raise Tool::Refusal, "The person who allowed this can no longer approve it. Ask for a new proposal."
      end

      saved = if workspace?
        @workspace.change_instructions(text, by: by, proposed_by: @agent, approval: approval)
      else
        @agent.change_instructions(text, approval: approval, invocation: @invocation)
      end
      raise Tool::Refusal, "The exact proposed instructions could not be saved." unless saved && @target.reload.instructions == text

      warning(text)
    end

    private
      def workspace? = @arguments["scope"] == "workspace"

      def warning(text) = (WARNING if text.length > WARN_AT)

      # Turning the tool off, or use_tool when the call came through it, withdraws every waiting card.
      def available?
        !@agent.tool_off?(Tool::ChangeYourself.tool_name) &&
          (@invocation.tool_name != "use_tool" || !@agent.tool_off?("use_tool"))
      end

      def digest(text) = Digest::SHA256.hexdigest(text)

      # The revision catches an edit that was changed back. Agent and owner
      # versions also cover moves and transfers that leave the text alone.
      def base
        owner = @workspace.owner_membership
        { "scope" => @arguments.fetch("scope", "yourself"), "target_id" => @target.id, "workspace_id" => @workspace.id,
          "revision_id" => @target.revisions.reorder(id: :desc).pick(:id), "text_digest" => digest(@before),
          "agent_id" => @agent.id, "agent_user_id" => @agent.user_id, "agent_version" => @agent.updated_at.utc.iso8601(6),
          "owner_membership_id" => owner&.id, "owner_id" => owner&.user_id, "owner_version" => owner&.updated_at&.utc&.iso8601(6) }
      end

      def edits = (@edits ||= Edits.new(@before, @arguments.fetch("edits")) if @arguments.key?("edits"))

      def result
        proposed = edits ? edits.result : @arguments.fetch("instructions")
        normalized = @target.class.normalize_value_for(:instructions, proposed)
        if edits && normalized != proposed
          raise Tool::Refusal, "Saving would change text outside the exact edits. Propose replacements that need no cleanup."
        end
        raise Tool::Refusal, "An agent's instructions cannot be blank." if !workspace? && normalized.blank?
        raise Tool::Refusal, "This proposal makes no change to the saved instructions." if normalized == @before

        normalized
      end
  end
end
