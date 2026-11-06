class Tool::RememberNote < Tool
  description "Save a note the person may want later, or replace the note with the same key."
  argument :key, :string, description: "A short name, such as dentist or gift-ideas.", pattern: "^[A-Za-z0-9_.-]{1,64}$"
  argument :body, :string, description: "The note itself.", min_length: 1, max_length: 16_384

  def call(key:, body:)
    note = bot.notes.remember(key, body)
    { key: note.key, body: note.body }
  end
end
