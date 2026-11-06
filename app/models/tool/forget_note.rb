class Tool::ForgetNote < Tool
  description "Delete a saved note by key. The person approves it first."
  argument :key, :string, pattern: "^[A-Za-z0-9_.-]{1,64}$"
  asks :approval

  def call(key:)
    note = bot.notes.find_by(key: key) or raise Refusal, "There is no note called #{key}."
    { forgotten: note.destroy!.key }
  end
end
