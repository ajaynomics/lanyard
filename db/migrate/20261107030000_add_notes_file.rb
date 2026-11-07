class AddNotesFile < ActiveRecord::Migration[8.2]
  def change
    # Whether the bot's notes file (AGENTS.md in its computer folder) is read;
    # on unless its owner turns it off.
    add_column :computers, :notes_file, :boolean, default: true, null: false
    # How large the notes file the conversation runs with is, as the sidecar
    # last said; nil when none is read.
    add_column :conversations, :notes_file_bytes, :integer
  end
end
