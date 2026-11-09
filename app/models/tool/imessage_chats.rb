# Finds chats on the person's phone, by a name, number or address in them.
class Tool::ImessageChats < Tool
  include Tool::Imessage

  description "Find chats in the person's iMessage by a person's name, phone number or email, or list the most recent. " \
    "Each comes with its GUID, which imessage_history and imessage_send take."
  argument :query, :string, required: false, max_length: 100, description: "Part of a name, number or address. Left out, the most recent chats."
  argument :limit, :integer, required: false, minimum: 1, maximum: 50, description: "At most this many; 20 when left out."

  def call(query: nil, limit: 20)
    chats = call_bluebubbles { bluebubbles.chats(query) }
    { chats: chats.first(limit), more: [ chats.size - limit, 0 ].max }
  end
end
