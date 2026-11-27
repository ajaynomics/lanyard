class CreateAgentVoiceCalls < ActiveRecord::Migration[8.2]
  def change
    create_table :agent_voice_calls do |t|
      t.references :agent, foreign_key: { on_delete: :nullify }
      t.string :body_digest, null: false
      t.string :delivery_id, null: false, index: { unique: true }
      t.string :event_id, index: { unique: true }
      t.string :session_id, index: { unique: true }
      t.timestamps
    end
  end
end
