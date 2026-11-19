# When Rails queued an outside call's job (claimed_at) and when that job
# began the call (started_at), so a call still waiting for a busy job role
# is not mistaken for one lost mid-call (Invocation#overdue, #238). Additive
# and nullable: a call already running, and one claimed by code from before
# during a rolling deploy, has neither, and keeps the rule it had.
class AddClaimedAtAndStartedAtToInvocations < ActiveRecord::Migration[8.2]
  def change
    add_column :invocations, :claimed_at, :datetime
    add_column :invocations, :started_at, :datetime
  end
end
