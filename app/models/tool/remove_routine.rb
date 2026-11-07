class Tool::RemoveRoutine < Tool
  description "Stop one of your routines for good, by its id from list_routines. The person approves it first."
  argument :id, :integer, minimum: 1
  asks :approval

  def call(id:)
    agent.routines.find(id).destroy!
    { removed: id }
  end
end
