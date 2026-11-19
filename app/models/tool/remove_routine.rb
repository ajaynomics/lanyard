class Tool::RemoveRoutine < Tool
  description "Stop one of your routines for good, or cancel a one-off before it runs, by its id from list_routines. The person approves it first."
  argument :id, :integer, minimum: 1
  asks :approval
  changes_itself

  def call(id:)
    agent.routines.find(id).destroy!
    { removed: id }
  end
end
