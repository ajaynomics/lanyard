require "net/http"
require "uri"

module DurableAssistants
  # iMessage, through a BlueBubbles server on the install owner's Mac
  # (docs/imessage.md). Its password opens every message on that Mac, so this
  # file is the only code that holds it, and it asks BlueBubbles for four
  # things: chats, a chat's messages, the contacts that name them, and sending
  # one text. BlueBubbles takes the password only in the query string, so no
  # error raised here carries a URL, a response body or an exception message
  # that could repeat one.
  module Bluebubbles
    CHATS = "/api/v1/chat/query"
    MESSAGES = "/api/v1/message/query"
    CONTACTS = "/api/v1/contact"
    SEND = "/api/v1/message/text"
    PATHS = [ CHATS, MESSAGES, CONTACTS, SEND ].freeze
    TIMEOUT = 15 # seconds for a read
    SEND_TIMEOUT = 60 # BlueBubbles answers a send once the message is in the Mac's database
    LABELS = 30.days # how long a chat's name is kept for the approval card

    class Error < StandardError; end
    # A send whose outcome nobody knows: it may have gone. Never sent again.
    class Unknown < Error; end

    def self.setting(key) = DurableAssistants.config(:bluebubbles, key).presence

    def self.configured? = setting(:url).present? && setting(:password).present?

    # Chats, most recent first, each with its name and the people in it; those
    # whose name, number or address contains `query` when one is given.
    def self.chats(query = nil)
      book = contacts
      chats = Array(request(CHATS, { limit: 1000, offset: 0, sort: "lastmessage", with: %w[ participants lastMessage ] })["data"]).map do |row|
        people = Array(row["participants"]).filter_map { it["address"] }
        chat = { guid: row["guid"], name: row["displayName"].presence || people.map { book.fetch(key(it), it) }.join(", ").presence || row["chatIdentifier"],
                 group: row["guid"].to_s.include?(";+;"), participants: people.map { named(it, book) },
                 last_at: time(row.dig("lastMessage", "dateCreated")) }
        Rails.cache.write(label_key(chat[:guid]), chat.slice(:name, :participants), expires_in: LABELS)
        chat
      end
      return chats if query.blank?
      words, digits = query.downcase, key(query)
      chats.select { |chat| [ chat[:name], *chat[:participants] ].any? { it.to_s.downcase.include?(words) || (digits.match?(/\A\d{7,}\z/) && key(it).end_with?(digits)) } }
    end

    def self.chat(guid) = chats.find { it[:guid] == guid }

    # One chat's messages, newest first: text, who sent it, when, attachment
    # names, and whether it was delivered. Reactions and system lines are left out.
    def self.messages(guid, limit:, offset: 0, after: nil)
      book = contacts
      answer = request(MESSAGES, { chatGuid: guid, limit: limit, offset: offset, sort: "DESC", with: %w[ handle attachment ], after: (after.to_i * 1000 if after) }.compact)
      rows = Array(answer["data"]).reject { it["associatedMessageType"].present? || it["isSystemMessage"] }.map do |row|
        { guid: row["guid"], from_me: row["isFromMe"] == true, from: (named(row.dig("handle", "address"), book) unless row["isFromMe"]),
          at: time(row["dateCreated"]), text: row["text"].to_s.strip, attachments: Array(row["attachments"]).filter_map { it["transferName"] },
          delivered: row["isDelivered"] == true || row["dateDelivered"].present?, error: row["error"].to_i }
      end
      { messages: rows, total: answer.dig("metadata", "total").to_i }
    end

    # One text into a chat. BlueBubbles answers with the message once it is in
    # the Mac's database; anything short of that is Unknown, never a failure.
    def self.send_text(guid, text)
      message = request(SEND, { chatGuid: guid, tempGuid: "lanyard-#{SecureRandom.uuid}", message: text, method: "apple-script" }, sending: true)["data"]
      raise Unknown, "BlueBubbles didn't confirm the message" unless message.is_a?(Hash) && message["guid"].present?
      raise Error, "iMessage refused it (error #{message["error"]})" if message["error"].to_i.nonzero?
      { guid: message["guid"], delivered: message["isDelivered"] == true }
    end

    # The chat's name and people as last listed, for the person approving a
    # send. A one-to-one chat's GUID names its number or address itself; a
    # group never listed is only its GUID, and says so.
    def self.label(guid)
      Rails.cache.read(label_key(guid)) ||
        { name: guid.to_s.include?(";+;") ? "a group chat not looked up (#{guid})" : guid.to_s.split(";").last, participants: [] }
    end

    def self.contacts
      Rails.cache.fetch("bluebubbles/contacts", expires_in: 10.minutes) do
        Array(request(CONTACTS)["data"]).each_with_object({}) do |contact, book|
          name = contact["displayName"].presence || [ contact["firstName"], contact["lastName"] ].compact.join(" ").presence || contact["nickname"].presence
          next unless name
          (Array(contact["phoneNumbers"]) + Array(contact["emails"])).each do |handle|
            address = handle.is_a?(Hash) ? handle["address"] : handle
            book[key(address)] ||= name.strip if address.present?
          end
        end
      end
    end
    private_class_method :contacts

    # A number's last ten digits, or an address in lower case: how the Mac's
    # contacts and its chats name the same person.
    def self.key(address)
      address = address.to_s.strip.downcase
      return address if address.include?("@")
      digits = address.gsub(/\D/, "")
      digits.present? ? digits.last(10) : address
    end
    private_class_method :key

    def self.named(address, book)
      name = book[key(address)]
      name ? "#{name} <#{address}>" : address
    end
    private_class_method :named

    def self.time(milliseconds) = (Time.at(milliseconds.to_i / 1000.0).utc.iso8601 if milliseconds.to_i.positive?)
    private_class_method :time

    def self.label_key(guid) = "bluebubbles/chat/#{Digest::SHA256.hexdigest(guid.to_s)}"
    private_class_method :label_key

    def self.request(path, body = nil, sending: false)
      raise ArgumentError, "BlueBubbles #{path} is not something this app asks for" unless PATHS.include?(path)
      raise ArgumentError, "only a send may send" if (path == SEND) != sending
      uri = URI.join(setting(:url).to_s.chomp("/") + "/", path.delete_prefix("/"))
      uri.query = URI.encode_www_form(password: setting(:password))
      http = body ? Net::HTTP::Post.new(uri, "Content-Type" => "application/json") : Net::HTTP::Get.new(uri)
      http.body = body.to_json if body
      timeout = sending ? SEND_TIMEOUT : TIMEOUT
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: timeout) { it.request(http) }
      answer = JSON.parse(response.body) rescue nil
      return answer if response.is_a?(Net::HTTPSuccess) && answer.is_a?(Hash)
      # A refused send may still have gone: BlueBubbles answers 500 when it
      # sent but didn't see the message land.
      raise (sending && !response.is_a?(Net::HTTPClientError) ? Unknown : Error), "BlueBubbles answered HTTP #{response.code}"
    rescue Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse => error
      raise (sending ? Unknown : Error), "BlueBubbles didn't answer (#{error.class.name.demodulize})"
    end
    private_class_method :request
  end
end
