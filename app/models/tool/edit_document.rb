# Targeted edits to a document in the canvas: the preferred way to change
# one, since the person may have edited the rest.
class Tool::EditDocument < Tool
  description "Change part of a document in the canvas: each edit replaces text that appears exactly once in it. Prefer " \
    "this to write_document for any change short of a rewrite: it keeps the rest, and the person's own edits, as they " \
    "are. Copy each find from the document exactly (read_document shows it); all edits apply, or none."
  argument :document_id, :integer, description: "The document, from write_document or read_document."
  argument :edits, :array, min_items: 1, max_items: 50, items: {
    type: "object", additionalProperties: false, required: %w[ find replace ],
    properties: { find: { type: "string", minLength: 1, maxLength: 20_000, description: "Text that appears exactly once." },
                  replace: { type: "string", maxLength: 20_000, description: "What it becomes." } } }

  def call(document_id:, edits:)
    document = agent.documents.find(document_id)
    document.edit(edits, by: "agent")
    Tool::ReadDocument.summary(document)
  rescue Document::EditRefused => refusal
    raise Refusal, "No edits applied. #{refusal.message}"
  end
end
