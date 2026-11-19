# Mail allowed outside the agent's sending hours, held until they open
# (HeldEmail): the call it came from, which holds the message, and when it
# goes. A new table, so code from before, running during a rolling deploy,
# neither reads nor writes it: that code sends at once, as before.
class CreateHeldEmails < ActiveRecord::Migration[8.2]
  def change
    create_table :held_emails do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :invocation, null: false, foreign_key: true, index: { unique: true }
      t.datetime :send_at, null: false
      t.string :state, null: false, default: "held"
      t.datetime :sent_at
      t.string :error
      t.references :cancelled_by, foreign_key: { to_table: :users }
      t.timestamps
      t.index %i[ state send_at ]
    end
  end
end
