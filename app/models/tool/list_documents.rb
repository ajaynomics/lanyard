# The agent's documents in the canvas, to find one by its title: newest
# first, deleted ones never among them.
class Tool::ListDocuments < Tool
  LIMIT = 100

  description "List the documents in the canvas, newest first: each one's document_id, title, when it last changed " \
    "and its size in characters. Optionally only those whose title contains some words."
  argument :title, :string, required: false, max_length: 200, description: "Words the title contains, in any case."
  argument :limit, :integer, required: false, minimum: 1, maximum: LIMIT, description: "How many at most: 20 unless said."

  def call(title: nil, limit: 20)
    documents = agent.documents.titled(title).with_size.order(updated_at: :desc, id: :desc).limit(limit)
    { documents: documents.map { { document_id: it.id, title: it.title, updated_at: it.updated_at.iso8601, size: it.size } } }
  end
end
