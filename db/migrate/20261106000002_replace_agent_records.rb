# The template's actor/workspace-keyed records become the domain's own:
# conversations of a user's bot, one invocation ledger for every tool, and
# notes that belong to a bot. Nothing was ever deployed with the old tables.
class ReplaceAgentRecords < ActiveRecord::Migration[8.2]
  def change
    drop_table :agent_effects do |t|
      t.string :workspace_id, null: false
      t.string :actor_id, null: false
      t.string :task_id, null: false
      t.string :call_id, null: false
      t.string :argument_digest, null: false
      t.json :result
      t.timestamps
    end
    drop_table :agent_notes do |t|
      t.string :workspace_id, null: false
      t.string :actor_id, null: false
      t.string :key, null: false
      t.text :body, null: false, default: ""
      t.timestamps
    end
    drop_table :agent_conversations do |t|
      t.string :workspace_id, null: false
      t.string :actor_id, null: false
      t.string :request_id, null: false
      t.string :durable_id, null: false
      t.timestamps
    end

    create_table :conversations do |t|
      t.references :user, null: false, foreign_key: true
      t.references :bot, null: false, foreign_key: true
      t.string :request_id, null: false
      t.string :durable_id, null: false
      t.string :title, null: false, default: ""
      t.string :status, null: false, default: "idle"
      t.string :definition_digest
      t.timestamps
    end
    add_index :conversations, [ :bot_id, :request_id ], unique: true
    add_index :conversations, [ :bot_id, :durable_id ], unique: true

    create_table :invocations do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :task_id, null: false
      t.string :call_id, null: false
      t.string :tool_name, null: false
      t.json :arguments, null: false, default: {}
      t.string :digest, null: false
      t.string :state, null: false, default: "pending"
      t.json :result
      t.string :error
      t.datetime :expires_at
      t.timestamps
    end
    add_index :invocations, [ :conversation_id, :task_id, :call_id ], unique: true

    create_table :approvals do |t|
      t.references :invocation, null: false, foreign_key: true, index: { unique: true }
      t.references :decided_by, null: false, foreign_key: { to_table: :users }
      t.string :decision, null: false
      t.datetime :created_at, null: false
    end

    create_table :answers do |t|
      t.references :invocation, null: false, foreign_key: true, index: { unique: true }
      t.references :decided_by, null: false, foreign_key: { to_table: :users }
      t.json :selections, null: false, default: []
      t.text :text, null: false, default: ""
      t.datetime :created_at, null: false
    end

    create_table :notes do |t|
      t.references :bot, null: false, foreign_key: true
      t.string :key, null: false
      t.text :body, null: false
      t.timestamps
    end
    add_index :notes, [ :bot_id, :key ], unique: true
  end
end
