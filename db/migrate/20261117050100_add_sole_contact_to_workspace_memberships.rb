# A member's only outbound contact in the workspace, one of its agents, and
# the number the app knows them by (Workspace::Membership#sole_contact). Both
# empty for every member now, so nothing changes until a member chooses;
# code from before never reads them. Deleting the agent clears the choice.
class AddSoleContactToWorkspaceMemberships < ActiveRecord::Migration[8.2]
  def change
    add_reference :workspace_memberships, :sole_contact, foreign_key: { to_table: :agents, on_delete: :nullify }
    add_column :workspace_memberships, :phone_number, :string
  end
end
