class CreateAgentRecords < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_conversations do |t|
      t.string :workspace_id, null: false
      t.string :actor_id, null: false
      t.string :request_id, null: false
      t.string :durable_id, null: false
      t.timestamps
    end
    add_index :agent_conversations, [ :workspace_id, :actor_id, :request_id ], unique: true, name: "agent_conversation_admission"
    add_index :agent_conversations, [ :workspace_id, :actor_id, :durable_id ], unique: true, name: "agent_conversation_identity"

    create_table :agent_notes do |t|
      t.string :workspace_id, null: false
      t.string :actor_id, null: false
      t.string :key, null: false
      t.text :body, null: false, default: ""
      t.timestamps
    end
    add_index :agent_notes, [ :workspace_id, :actor_id, :key ], unique: true, name: "agent_note_identity"

    create_table :agent_effects do |t|
      t.string :workspace_id, null: false
      t.string :actor_id, null: false
      t.string :task_id, null: false
      t.string :call_id, null: false
      t.string :argument_digest, null: false
      t.json :result
      t.timestamps
    end
    add_index :agent_effects, [ :workspace_id, :actor_id, :task_id, :call_id ], unique: true, name: "agent_effect_identity"
  end
end
