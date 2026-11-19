module DocumentsHelper
  # Code in a fence longer than any run of backticks inside it, so the
  # Markdown renderer's highlighter colours it and nothing in it ends it.
  def document_code(document)
    fence = "`" * [ 3, document.body.scan(/`+/).map(&:size).max.to_i + 1 ].max
    markdown("#{fence}#{document.language}\n#{document.body}\n#{fence}")
  end

  # Its length, as a person reads it: "1,204 characters".
  def document_size(document) = "#{number_with_delimiter(document.size)} #{"character".pluralize(document.size)}"

  # The frame beside a thread that the canvas opens in.
  def canvas_frame_id(conversation) = dom_id(conversation, :canvas)

  # The document a call that wrote or edited one left, for its card in the thread.
  def invocation_document(invocation)
    return unless invocation.tool_name.in?(%w[ write_document edit_document ]) && invocation.result.is_a?(Hash)
    invocation.agent.documents.find_by(id: invocation.result.stringify_keys["document_id"])
  end
end
