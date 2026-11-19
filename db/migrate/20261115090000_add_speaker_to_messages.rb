# Who said a message, as the sidecar's entry keeps it (agent/state.mjs's
# MessageEntry): its request id, and its author, a person (author_id) or a
# channel's sender. Additive: a message from before has none and is read from
# its words, as before; code from before ignores the columns. No foreign key:
# a person's words stay theirs in a thread they no longer reach, and the copy
# is rebuilt from the sidecar, which never fails on a person since removed.
class AddSpeakerToMessages < ActiveRecord::Migration[8.2]
  def change
    add_column :messages, :request_id, :string
    add_column :messages, :author_id, :integer
    add_column :messages, :sender, :string
  end
end
