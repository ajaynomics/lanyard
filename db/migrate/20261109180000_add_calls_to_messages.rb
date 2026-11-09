# A helper's result keeps the calls it made, settled, to show under its line
# after it answers (subagent.mjs): their number, and the newest of them.
class AddCallsToMessages < ActiveRecord::Migration[8.2]
  def change
    add_column :messages, :calls, :json
    add_column :messages, :call_count, :integer
  end
end
