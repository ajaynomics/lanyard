# Deletes a document in the canvas softly (Document::Deletable). It asks
# nobody first: the owner judged the 30 days to restore it, and this call in
# the thread's ledger, enough.
class Tool::DeleteDocument < Tool
  description "Delete a document in the canvas. It leaves every list and read at once; the person can restore it " \
    "from Recently deleted for 30 days, after which it is gone for good."
  argument :document_id, :integer, description: "The document, from list_documents or read_document."

  def call(document_id:)
    document = agent.documents.find(document_id)
    document.soft_delete(by: "agent")
    { document_id: document.id, title: document.title, restorable_until: document.purge_at.iso8601 }
  end
end
