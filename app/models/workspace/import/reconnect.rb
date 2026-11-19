# What a connector that came needs before it works here (docs/import.md). No
# sign-in comes, nor any key: one made through the other install's OAuth
# client is that client's, and a key was given to the other install, not this
# one. A connector that signed in is marked to sign in again, one click on
# its Connectors page; one that held a key says to add it again with its key.
class Workspace::Import::Reconnect
  SIGN_IN = %w[ oauth_client oauth_tokens oauth_pending oauth_state ].freeze
  KEYS = %w[ token headers env ].freeze

  SIGN_IN_AGAIN = "sign in again"
  ADD_AGAIN = "add it again with its key"

  # How the owner reconnects it, or nil for one that needed neither.
  def self.how(row)
    if KEYS.any? { row[it].present? } then ADD_AGAIN
    elsif signs_in?(row) then SIGN_IN_AGAIN
    end
  end

  def self.signs_in?(row)
    KEYS.none? { row[it].present? } &&
      (row["sign_in_needed"].to_i == 1 || [ *SIGN_IN, "oauth_app", "oauth_scope" ].any? { row[it].present? })
  end

  # What its Connectors page says until it is reconnected.
  def self.problem(row)
    case how(row)
    when ADD_AGAIN then "Came from another install; its key stayed with the other install: remove it and add it again with its key."
    when SIGN_IN_AGAIN then "Came from another install, without its sign-in: sign in again."
    end
  end

  # Each connector that came and needs reconnecting, by name.
  def self.all(run)
    list = []
    run.source.each("mcp_servers") do |row|
      next unless run.id("mcp_servers", row["id"]) && (how = how(row))
      list << { "name" => row["name"], "how" => how, "thread" => row["conversation_id"].present? }
    end
    list
  end
end
