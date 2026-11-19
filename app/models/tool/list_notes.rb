class Tool::ListNotes < Tool
  LIMIT = 50
  PREVIEW = 2_000

  description "List saved notes, newest first, optionally only those containing some words. " \
    "A long note shows its start, marked cut; pass its exact key to get it whole."
  argument :query, :string, required: false, max_length: 200,
    description: "Words the note's key or body contains, or a note's exact key to get it whole."

  # A note named exactly comes whole and first: an agent adds to a note by
  # reading it and saving it back, and remember_note replaces the whole body,
  # so a preview read back would cut the note short for good.
  def call(query: nil)
    whole = agent.notes.find_by(key: query) if query.present?
    notes = agent.notes.matching(query).where.not(id: whole).order(updated_at: :desc).limit(LIMIT - (whole ? 1 : 0))
    { notes: [ (entry(whole, whole: true) if whole), *notes.map { entry(it) } ].compact }
  end

  private
    def entry(note, whole: false)
      listed = { key: note.key, body: note.body, updatedAt: note.updated_at.iso8601 }
      return listed if whole || note.body.length <= PREVIEW
      listed.merge(body: note.body[0, PREVIEW], length: note.body.length,
        cut: "Only the first #{PREVIEW} of #{note.body.length} characters. list_notes with its exact key gives it whole.")
    end
end
