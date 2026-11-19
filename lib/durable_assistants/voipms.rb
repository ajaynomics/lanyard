require "net/http"
require "uri"

module DurableAssistants
  # Texts from an agent's own number, through voip.ms (docs/phone.md). Its API
  # password is the whole account's, with no narrower key, so this file is the
  # only code that holds it and may ask for exactly four things: send a text,
  # send a longer one as MMS, and list the texts or MMS one number sent one
  # recipient, to find a send whose answer never came. Those lists are the one
  # read, a narrow addition to what was a send-only module: only after a send
  # timed out (at once, then from Dispatch#check until it settles), only the
  # agent's own number to the same recipient, and only to say whether that
  # text went. Nothing else reads the account, its numbers or its messages.
  # The account is the install's, or a workspace's own (Account), whose
  # password this file alone reads from the vault, for each request.
  module Voipms
    URL = URI("https://voip.ms/api/v1/rest.php")
    METHODS = %w[ sendSMS sendMMS getSMS getMMS ].freeze
    SMS_LIMIT = 160 # characters; longer goes as one MMS, up to MMS_LIMIT
    MMS_LIMIT = 2048
    TIMEOUT = 15 # seconds to connect, and to answer a lookup
    # voip.ms has answered a send after 17 to 19 seconds, having sent it.
    SEND_TIMEOUT = 45
    # Its clock and ours may differ; a match must still be the same words, from and to the same numbers.
    CLOCK_SLACK = 2.minutes
    # Failures after the send may have reached voip.ms: the text may have gone.
    MAY_HAVE_GONE = [ Net::ReadTimeout, Net::WriteTimeout, EOFError, Errno::ECONNRESET, Errno::EPIPE ].freeze
    # Failures before it could: nothing was sent.
    NOT_SENT = [ Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, OpenSSL::SSL::SSLError ].freeze

    class Error < StandardError; end

    # voip.ms gave no answer to a send and doesn't list it: it may have gone.
    # Not an Error, which is a refusal: this text must not be sent again.
    class Unconfirmed < StandardError; end

    # A workspace's own account (Workspace#voipms_account): the vault entry
    # holding its API username and password, read as `reader`, one of its
    # agents. Holds the entry's name, never what is in it.
    Account = Data.define(:vault_entry, :reader) do
      def inspect = "#<Voipms::Account #{vault_entry}>"
      alias_method :to_s, :inspect
    end

    def self.setting(key) = DurableAssistants.config(:voipms, key).presence

    # A workspace's own account needs none of the install's.
    def self.configured?(account = nil) = account.present? || (setting(:username).present? && setting(:password).present?)

    # One text from `from` to `to`, both ten digits, through `account`, or the
    # install's without one. voip.ms's id for it.
    def self.send_text(from:, to:, body:, account: nil)
      kind = body.length <= SMS_LIMIT ? "SMS" : "MMS"
      started = Time.current
      answer = request("send#{kind}", account:, read_timeout: SEND_TIMEOUT, did: from, dst: to, message: body)
      answer["sms"] || answer["mms"]
    rescue *MAY_HAVE_GONE
      found = begin
        sent_id(from: from, to: to, body: body, since: started, account: account)
      rescue Error
      end
      found or raise Unconfirmed, "voip.ms didn't answer in time and doesn't list the text"
    rescue *NOT_SENT => problem
      raise Error, "Could not reach voip.ms (#{problem.class.name.demodulize}), so the text was not sent."
    end

    # The id of the text `from` sent `to` with these words since `since`, as
    # voip.ms lists it (among MMS for a long one), asked of the account that
    # sent it; nil when it doesn't. An Error when the list can't be had, which
    # says nothing either way.
    def self.sent_id(from:, to:, body:, since:, account: nil)
      method = body.length <= SMS_LIMIT ? "getSMS" : "getMMS"
      answer = begin
        request(method, account:, nothing: %w[ no_sms no_mms ], did: from, contact: to, type: 0, timezone: 0, limit: 50,
          from: (since - 1.day).utc.to_date.iso8601, to: 1.day.from_now.utc.to_date.iso8601)
      rescue *MAY_HAVE_GONE, *NOT_SENT => problem
        raise Error, "Could not ask voip.ms what was sent (#{problem.class.name.demodulize})"
      end
      found = Array(answer["sms"] || answer["mms"]).select do |message|
        message.is_a?(Hash) && message["did"].to_s == from && message["contact"].to_s == to && message["type"].to_s == "0" &&
          message["message"].to_s == body && sent_at(message["date"])&.after?(since - CLOCK_SLACK)
      end
      found.map { it["id"].to_s }.select { it.match?(/\A\d+\z/) }.map(&:to_i).max
    end

    # Asked for in UTC (timezone 0).
    def self.sent_at(date) = (Time.find_zone!("UTC").strptime(date.to_s, "%Y-%m-%d %H:%M:%S") rescue nil)
    private_class_method :sent_at

    # A POST, so the password is never in a URL that something might log. As
    # multipart/form-data: voip.ms answers a URL-encoded form with a SOAP
    # "Bad Request" (HTTP 500), and takes the same fields as multipart.
    # `nothing`: the statuses voip.ms answers a list with when it has none.
    def self.request(method, account:, read_timeout: TIMEOUT, nothing: [], **params)
      raise ArgumentError, "voip.ms #{method} is not something this app asks for" unless METHODS.include?(method)
      username, password = credentials(account)
      post = Net::HTTP::Post.new(URL)
      multipart(post, api_username: username, api_password: password, method: method, **params)
      response = Net::HTTP.start(URL.host, URL.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: read_timeout) { it.request(post) }
      answer = JSON.parse(response.body) rescue nil
      raise Error, "voip.ms answered HTTP #{response.code} (not JSON)" unless answer.is_a?(Hash)
      return answer if response.is_a?(Net::HTTPSuccess) && answer["status"] == "success"
      return {} if response.is_a?(Net::HTTPSuccess) && nothing.include?(answer["status"])
      raise Error, "voip.ms refused the text: #{answer["status"].presence || "HTTP #{response.code}"}"
    end
    private_class_method :request

    # The install's, or read from the vault for this one request and never
    # kept. An entry saved for another site, or for none, is refused, so no
    # other site's password is sent to voip.ms. An Error, before anything is
    # sent, when it can't be read.
    def self.credentials(account)
      return [ setting(:username), setting(:password) ] unless account
      entry = Passbolt.sign_in(account.reader, Passbolt.find_by_name(account.reader, account.vault_entry).id)
      raise Error, "#{account.vault_entry} is saved for #{entry.host || "no address"}, not voip.ms, so it is not sent there." unless
        entry.host == URL.host || entry.host&.end_with?(".#{URL.host}")
      raise Error, "#{account.vault_entry} has no voip.ms API username and password saved." if entry.username.blank? || entry.password.blank?
      [ entry.username, entry.password ]
    rescue Passbolt::Error => error
      raise Error, error.message
    end
    private_class_method :credentials

    # Built here rather than by Net::HTTP#set_form, which builds it only as it
    # sends, so a test could not read what was sent.
    def self.multipart(post, **fields)
      boundary = SecureRandom.hex(24)
      post.content_type = "multipart/form-data; boundary=#{boundary}"
      post.body = fields.map { |name, value| %(--#{boundary}\r\nContent-Disposition: form-data; name="#{name}"\r\n\r\n#{value}\r\n) }.join.b +
        "--#{boundary}--\r\n"
    end
    private_class_method :multipart
  end
end
