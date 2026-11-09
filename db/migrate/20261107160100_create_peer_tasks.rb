# A Concourse task linked to the conversation (agent) it belongs to:
# one a peer sent the bot, or one the bot sent.
class CreatePeerTasks < ActiveRecord::Migration[8.2]
  def change
    create_table :peer_tasks do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :task_id, null: false
      t.string :context_id
      t.string :peer, null: false
      t.string :direction, null: false
      t.string :state, null: false
      # What has reached the conversation already: the peer's message ids
      # (inbound), or the status updates passed on (outbound).
      t.json :delivered_ids, default: [], null: false
      t.timestamps
      t.index %i[ conversation_id task_id ], unique: true
      t.index :task_id
    end
  end
end
