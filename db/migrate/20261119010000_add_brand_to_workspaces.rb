# A workspace's own name, colour and link host (Brand, #229). None, as for
# every workspace until now: the install's.
class AddBrandToWorkspaces < ActiveRecord::Migration[8.2]
  def change
    add_column :workspaces, :app_name, :string
    add_column :workspaces, :accent_hue, :integer
    add_column :workspaces, :link_host, :string
  end
end
