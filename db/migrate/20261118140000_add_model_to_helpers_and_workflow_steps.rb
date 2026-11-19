# The model and thinking a helper ran on, as the sidecar reports them, and
# those a workflow's step asked for (agent/subagent.mjs chooseModel). Empty on
# existing rows: they ran on their agent's own, which they never named.
class AddModelToHelpersAndWorkflowSteps < ActiveRecord::Migration[8.2]
  def change
    add_column :helpers, :model, :string
    add_column :helpers, :thinking_level, :string
    add_column :workflow_steps, :model, :string
    add_column :workflow_steps, :thinking_level, :string
  end
end
