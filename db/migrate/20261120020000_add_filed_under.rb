# The client file or matter a run's work is filed under (Tool::FileUnder,
# #277): on the thread while its run lasts, on a helper from its start, and
# on what each call used. None for every row until now: untagged.
class AddFiledUnder < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :filed_under, :string
    add_column :helpers, :filed_under, :string
    add_column :model_usages, :filed_under, :string
  end
end
