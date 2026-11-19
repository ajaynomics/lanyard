require "net/http"
require "json"

module DurableAssistants
  # Telegram's Bot API, as one agent's bot (TelegramBot): the only code that
  # holds a bot's token, which comes from the vault for each call and goes
  # nowhere but Telegram. The Bot API takes it in the request's path, so no
  # error here ever carries a URL, a path or what Telegram sent back beyond
  # its own one-line description.
  module Telegram
    HOST = "api.telegram.org".freeze
    TIMEOUT = 15 # seconds
    FILE_TIMEOUT = 60 # each read of a file's bytes
    # BotFather's form, "123456789:AA…". Anything else could change the path it goes in.
    TOKEN = /\A\d{1,20}:[A-Za-z0-9_-]{30,100}\z/
    # Where getFile says a file is, as "documents/file_7.pdf".
    FILE_PATH = %r{\A[A-Za-z0-9_-]+(/[A-Za-z0-9_.-]+)*\z}
    METHODS = %w[ getMe setWebhook deleteWebhook sendMessage getFile ].freeze
    # The connection was never made, so nothing went.
    NOT_SENT = [ Net::OpenTimeout, SocketError, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, OpenSSL::SSL::SSLError ].freeze
    # The request may have reached Telegram: whether it acted is unknown.
    MAYBE = [ Timeout::Error, SystemCallError, IOError, Net::HTTPBadResponse ].freeze

    # Something went wrong, in words a person or a model can read; nothing was done.
    class Error < StandardError; end
    # Telegram may or may not have done it.
    class Unknown < Error; end

    def self.token?(token) = token.to_s.match?(TOKEN)

    def self.me(token) = call(token, "getMe")

    def self.set_webhook(token, url:, secret:) = call(token, "setWebhook", url: url, secret_token: secret, allowed_updates: [ "message" ])

    def self.delete_webhook(token) = call(token, "deleteWebhook")

    # One message; Telegram's id for it.
    def self.send_message(token, chat:, text:) = call(token, "sendMessage", chat_id: chat, text: text)["message_id"]

    # Where a file a bot was sent is, and its size: Telegram keeps it an hour at least.
    def self.file(token, id) = call(token, "getFile", file_id: id)

    # A file's bytes, as a Tempfile, never whole in memory.
    def self.download(token, path)
      raise Error, "Telegram named the file oddly, so it wasn't fetched." unless path.to_s.match?(FILE_PATH)
      file = Tempfile.new("telegram", binmode: true)
      Net::HTTP.start(HOST, 443, use_ssl: true, open_timeout: TIMEOUT, read_timeout: FILE_TIMEOUT) do |http|
        http.request(Net::HTTP::Get.new("/file/bot#{checked(token)}/#{path}")) do |response|
          raise Error, "Telegram answered HTTP #{response.code} for the file." unless response.is_a?(Net::HTTPSuccess)
          response.read_body { file.write(it) }
        end
      end
      file.tap(&:flush).tap(&:rewind)
    rescue *NOT_SENT, *MAYBE => problem
      file&.close!
      raise Error, "Telegram didn't send the file (#{problem.class.name.demodulize})."
    rescue Error
      file&.close!
      raise
    end

    # A POST of JSON, as the Bot API takes every method. Its result, or Error
    # with Telegram's description. A send that may have arrived is Unknown.
    def self.call(token, method, **params)
      raise ArgumentError, "Telegram's #{method} is not something this app asks for" unless METHODS.include?(method)
      post = Net::HTTP::Post.new("/bot#{checked(token)}/#{method}", "Content-Type" => "application/json")
      post.body = params.to_json
      response = Net::HTTP.start(HOST, 443, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(post) }
      answer = JSON.parse(response.body.to_s) rescue nil
      return answer["result"] if response.is_a?(Net::HTTPSuccess) && answer.is_a?(Hash) && answer["ok"] == true
      why = answer.is_a?(Hash) && answer["description"].is_a?(String) ? answer["description"].truncate(200) : "HTTP #{response.code}"
      # A client error is Telegram refusing it; anything else may have been done.
      raise (response.is_a?(Net::HTTPClientError) ? Error : Unknown), "Telegram refused: #{why}"
    rescue *NOT_SENT => problem
      raise Error, "Couldn't reach Telegram (#{problem.class.name.demodulize})."
    rescue *MAYBE => problem
      raise Unknown, "Telegram didn't answer (#{problem.class.name.demodulize})"
    end

    def self.checked(token)
      raise Error, "That isn't a Telegram bot token." unless token?(token)
      token
    end
    private_class_method :checked
  end
end
