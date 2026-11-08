# Reads a document in the canvas as it is now, the person's edits included,
# or lists them all.
class Tool::ReadDocument < Tool
  LIMIT = 100

  description "Read a document in the canvas as it is now, the person's edits included. Without document_id, list the documents."
  argument :document_id, :integer, required: false
  argument :line_numbers, :boolean, required: false, description: "Number the lines, to find text to edit. The numbers are not part of it."

  def self.summary(document)
    { document_id: document.id, title: document.title, kind: document.kind, language: document.language, version: document.number }.compact
  end

  def call(document_id: nil, line_numbers: false)
    return { documents: agent.documents.order(updated_at: :desc).limit(LIMIT).map { self.class.summary(it).merge(updated_at: it.updated_at.iso8601) } } unless document_id
    document = agent.documents.find(document_id)
    body = line_numbers ? document.body.lines.each_with_index.map { |line, index| "#{index + 1}\t#{line}" }.join : document.body
    document.seen!
    self.class.summary(document).merge(body: body)
  end
end
