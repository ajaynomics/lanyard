# Bookkeeping on the agent's own thread, so it asks nobody and reaches nobody
# (docs/billing.md, #277).
class Tool::FileUnder < Tool
  LIMIT = 100

  description "Set the client file or matter number for new usage records on this conversation. " \
    "When the work is about one client file or matter, call this with its number before doing the work. " \
    "It lasts until this run ends; a blank label stops filing."
  argument :label, :string, max_length: 1_000, description: "The client file or matter number, such as EXAMPLE-FILE-A. Blank to stop filing."

  def call(label:)
    conversation.update!(filed_under: label.strip.first(LIMIT).presence)
    { filedUnder: conversation.filed_under }
  end
end
