require "base64"

module DurableAssistants::Google
  # Only the three reads an inbox needs; even a grant with other scopes
  # cannot send or change mail through this client.
  class GmailInbox
    class ExpiredHistory < Error; end
    Profile = Data.define(:email, :history_id)
    Page = Data.define(:message_ids, :next_page_token, :history_id)
    RawMessage = Data.define(:body, :label_ids)

    def initialize(token)
      @token = token
    end

    def profile
      answer = get("profile")
      email = answer["emailAddress"].to_s.strip.downcase.presence or raise Error, "Gmail returned no mailbox"
      Profile.new(email, history_id(answer))
    end

    def history(start, page_token:)
      answer = get("history", startHistoryId: start, historyTypes: "messageAdded", labelId: "INBOX", pageToken: page_token)
      ids = Array(answer["history"]).flat_map do |entry|
        Array(entry["messagesAdded"]).filter_map { |added| added.dig("message", "id").presence }
      end
      Page.new(ids.uniq, answer["nextPageToken"].presence, history_id(answer))
    rescue NotFound
      raise ExpiredHistory, "Gmail history expired"
    end

    def raw_message(id)
      answer = get("messages/#{ERB::Util.url_encode(id)}", format: "raw")
      raw = answer["raw"].presence
      raise Error, "Gmail returned no raw message" unless raw

      RawMessage.new(Base64.urlsafe_decode64(raw), Array(answer["labelIds"]))
    rescue ArgumentError
      raise Error, "Gmail returned invalid raw mail"
    end

    private
      def get(path, query = nil) = DurableAssistants::Google.request(@token, :get, "#{GMAIL}/#{path}", query: query)

      def history_id(answer)
        id = answer["historyId"].to_s
        return id if id.match?(/\A[0-9]+\z/)

        raise Error, "Gmail returned no history ID"
      end
  end
end
