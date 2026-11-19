# What the sidecar last said each of a thread's models and tools had used in
# all, so the next report records only what was added since (ModelUsage).
# Empty on existing threads: their next report starts the count, rather than
# counting their whole history as new.
class AddMeteredUsageToConversations < ActiveRecord::Migration[8.2]
  def change
    add_column :conversations, :metered_usage, :json
  end
end
