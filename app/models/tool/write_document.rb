# The agent's canvas (Document): a document beside the thread that the person
# reads, edits and exports. Its own scratch space, so nothing asks first.
class Tool::WriteDocument < Tool
  description "Write a document the person sees beside the thread, in the canvas: a draft, a plan, code, a page. Use it " \
    "for anything longer than a few paragraphs that the person may edit, copy or download. Writing a document that " \
    "exists (by document_id, or the same title) replaces its whole body: to change part of one, use edit_document instead."
  argument :title, :string, min_length: 1, max_length: 200
  argument :body, :string, min_length: 1, max_length: Document::BODY_LIMIT, description: "The whole document."
  argument :kind, :string, required: false, enum: Document::KINDS.keys,
    description: "markdown (the default), or code: say its language. A web page or an SVG is code, shown as its source."
  argument :language, :string, required: false, pattern: "^[A-Za-z0-9_+#.-]{1,32}$", description: "For code: ruby, python, javascript and so on."
  argument :document_id, :integer, required: false, description: "The document to replace, from read_document. Renames it to the title."

  def call(title:, body:, kind: nil, language: nil, document_id: nil)
    document = document_id ? agent.documents.find(document_id) : agent.documents.find_or_initialize_by(title: title)
    Document.transaction do
      document.update!({ title: title, kind: kind, language: language }.compact)
      document.revise(body, by: "agent")
    end
    document.seen!
    Tool::ReadDocument.summary(document)
  end
end
