# A call waiting on a person's approval while messages wait for the agent is
# handed back to Rails (Invocation#hand_back), so the agent reads them. Rails
# then runs it if the person allows it and tells the agent. Additive and
# nullable: every existing call, and one made by code from before during a
# rolling deploy, stays the sidecar's to wait on.
class AddHandedBackAtToInvocations < ActiveRecord::Migration[8.2]
  def change
    add_column :invocations, :handed_back_at, :datetime
  end
end
