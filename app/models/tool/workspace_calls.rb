# What the workspace tools share. They do what the workspace and agent pages
# do, through the same model methods, for the owner of the agent's workspace,
# and only she answers their cards. Everyone in a workspace reads what its
# agent says, so the agent names only what they all may know: in its
# person's own workspace, each of her workspaces; in a shared one, that one
# alone. A name it may not use, or a change she may not make, is refused
# before anyone is asked.
module Tool::WorkspaceCalls
  def approver = person

  def refusal
    check
    nil
  rescue Tool::Refusal => refusal
    refusal.message
  end

  private
    # What the call names, raising a Tool::Refusal the agent reads where it can't be done.
    def check = nil

    def person = agent.workspace.owner

    def nameable = agent.workspace.personal? ? person.workspaces.personal_first.to_a : [ agent.workspace ]

    # One of the workspaces it may name, by the name the person sees; none, its own.
    def workspace_named(name)
      return agent.workspace if name.blank?
      found = nameable.select { it.to_s.casecmp?(name.squish) }
      raise Tool::Refusal, "No workspace you can name is called #{name}. You can name #{nameable.map(&:to_s).to_sentence}." if found.none?
      raise Tool::Refusal, "More than one workspace is called #{name}. Rename one first." if found.many?
      found.sole
    end

    # One the person owns and shares, as only its owner invites and removes.
    def owned_workspace_named(name, to:)
      workspace_named(name).tap do |workspace|
        raise Tool::Refusal, "#{workspace} is #{person}'s own workspace, which nobody else joins." if workspace.personal?
        raise Tool::Refusal, "Only #{workspace.owner}, who owns #{workspace}, can #{to}." unless workspace.owner == person
      end
    end

    def refuse_unless_saved(record)
      raise Tool::Refusal, record.errors.full_messages.to_sentence if record.errors.any? || record.new_record?
    end
end
