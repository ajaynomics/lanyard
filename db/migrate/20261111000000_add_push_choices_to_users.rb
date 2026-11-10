# Which notifications a person wants, by kind (Push.deliver): an agent's
# replies, an agent that needs them, and something that went wrong. All on
# until they turn one off in Settings, as notifications were before.
class AddPushChoicesToUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :push_messages, :boolean, default: true, null: false
    add_column :users, :push_needs_you, :boolean, default: true, null: false
    add_column :users, :push_errors, :boolean, default: true, null: false
  end
end
