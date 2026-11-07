class Tool::ListNotes < Tool
  LIMIT = 50

  description "List saved notes, newest first, optionally only those containing some words."
  argument :query, :string, required: false, description: "Words the note's key or body contains.", max_length: 200

  def call(query: nil)
    notes = agent.notes.matching(query).order(updated_at: :desc).limit(LIMIT)
    { notes: notes.map { { key: it.key, body: it.body.truncate(2_000), updatedAt: it.updated_at.iso8601 } } }
  end
end
