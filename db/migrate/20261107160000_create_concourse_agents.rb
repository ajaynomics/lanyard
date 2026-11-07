# A bot's identity on Concourse (docs/design/PARITY.md §26): the machine
# client the Concourse operator bound to one named agent, and the inbox cursor.
class CreateConcourseAgents < ActiveRecord::Migration[8.2]
  def change
    create_table :concourse_agents do |t|
      t.references :bot, null: false, foreign_key: true, index: { unique: true }
      t.string :organization, null: false
      t.string :handle, null: false
      t.string :client_id, null: false
      t.text :client_secret, null: false # encrypted
      t.string :cursor
      t.datetime :checked_at
      t.string :check_error
      t.timestamps
    end
  end
end
