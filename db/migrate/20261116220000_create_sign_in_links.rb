# One-time links for someone outside the install to fill one empty saved
# sign-in (SignInLink). Only the token's digest is kept, and nothing the
# visitor types. A new table, so code from before, running during a rolling
# deploy or after a rollback, neither reads nor writes it; its keys cascade,
# so that code can still delete the conversation, call or person it names.
class CreateSignInLinks < ActiveRecord::Migration[8.2]
  def change
    create_table :sign_in_links do |t|
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.references :invocation, null: false, foreign_key: { on_delete: :cascade }
      t.references :revoked_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :entry_id, null: false
      t.string :name, null: false
      t.string :token_digest, null: false, index: { unique: true }
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.string :outcome
      t.timestamps
    end
  end
end
