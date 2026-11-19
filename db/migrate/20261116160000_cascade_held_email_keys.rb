# A held email goes with its conversation and call, and forgets who cancelled
# it when that person goes, in the database itself. Code from before held
# emails (a rollback image) deletes those rows without knowing this table, and
# a plain foreign key would fail that delete. Only the keys change; the rows
# stay.
class CascadeHeldEmailKeys < ActiveRecord::Migration[8.2]
  def change
    remove_foreign_key :held_emails, :conversations
    remove_foreign_key :held_emails, :invocations
    remove_foreign_key :held_emails, :users, column: :cancelled_by_id
    add_foreign_key :held_emails, :conversations, on_delete: :cascade
    add_foreign_key :held_emails, :invocations, on_delete: :cascade
    add_foreign_key :held_emails, :users, column: :cancelled_by_id, on_delete: :nullify
  end
end
