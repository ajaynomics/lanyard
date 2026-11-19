class Tool::RememberNote < Tool
  description "Save a note the person may want later, or replace the whole note with the same key. " \
    "To add to a note, read it whole first: list_notes with its exact key."
  argument :key, :string, description: "A short name, such as dentist or gift-ideas.", pattern: "^[A-Za-z0-9_.-]{1,64}$"
  argument :body, :string, description: "The note itself, all of it: this replaces what the note held.", min_length: 1, max_length: 16_384

  def call(key:, body:)
    note = agent.notes.remember(key, body)
    { key: note.key, body: note.body }
  end
end
