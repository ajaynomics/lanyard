# Whether a thread's own run is going, kept apart from whether a card waits
# on the person (Conversation::Activity). Additive: `status` stays, and code
# from before this keeps reading and writing it during a rolling deploy, since
# it only ever holds values that code accepts (an unknown run is "running").
# A waiting thread can't say from here whether its run still goes, so it
# starts unknown and the next frame or page load asks the sidecar; a
# migration makes no network call.
class AddExecutionStatusToConversations < ActiveRecord::Migration[8.2]
  def up
    add_column :conversations, :execution_status, :string, default: "idle", null: false
    execute "UPDATE conversations SET execution_status = status WHERE status IN ('running', 'error')"
    execute "UPDATE conversations SET execution_status = 'unknown' WHERE status = 'waiting'"
  end

  def down
    remove_column :conversations, :execution_status
  end
end
