# What became of each Turn on in the phone app, so an operator can see why a
# phone never turned notifications on: never a token, only the outcome.
class CreatePushAttempts < ActiveRecord::Migration[8.2]
  def change
    create_table :push_attempts do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :outcome, null: false
      t.integer :code
      t.string :user_agent, null: false, default: ""
      t.datetime :created_at, null: false
    end
  end
end
