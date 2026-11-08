require "net/http"
require "uri"

module DurableAssistants
  # Campfire's administrator pages, driven as an administrator would, so an
  # agent gets its own bot when it is made (docs/campfire.md). Stock ONCE
  # Campfire has no API for bots, so this signs in with the session form and
  # uses the bot forms, pinned to them as of v1.5.8
  # (test/lib/campfire_v1_5_8 holds the recorded pages). When a page no longer
  # looks as recorded, it raises Changed and the person sets the bot up by
  # hand; it never guesses. This file is the only code that knows those pages.
  module Campfire
    PINNED = "v1.5.8"
    # How v1.5.8 stores a mention in a message's HTML: an attachment of this type, holding only a signed user id.
    MENTION = "application/vnd.campfire.mention".freeze
    TIMEOUT = 10 # seconds

    class Error < StandardError; end

    # A page is not what v1.5.8 served: the bot is set up by hand.
    class Changed < Error
      def initialize(what) = super("Campfire's #{what} isn't as #{PINNED} had it, so the bot can't be made here. Set it up by hand in Campfire.")
    end

    def self.setting(key) = DurableAssistants.config(:campfire, key).presence

    # Bots are made on their own only with an administrator to sign in as.
    def self.admin? = setting(:url).present? && setting(:admin_email).present? && setting(:admin_password).present?

    def self.admin = Admin.new(setting(:url), setting(:admin_email), setting(:admin_password))

    # The Campfire user id at the front of a bot's key, "4-abc123".
    def self.bot_id(key) = Integer(key.to_s[/\A(\d+)-/, 1])

    class Admin
      def initialize(url, email, password)
        @base, @email, @password = URI(url.to_s.delete_suffix("/") + "/"), email, password
        @cookies = {}
      end

      # A bot named `name` that Campfire calls at `webhook_url`; it joins every
      # open room. Its key, "<id>-<token>", read from the bots page.
      def create_bot(name:, webhook_url:)
        signed_in do
          form = form_on("account/bots/new", action: "/account/bots", what: "new bot form", fields: %w[ user[name] user[webhook_url] ])
          submit form, "user[name]" => name, "user[webhook_url]" => webhook_url, expect: "/account/bots"

          page = get("account/bots", what: "bots page")
          id = page.css("a[href^='/account/bots/'][href$='/edit']").filter_map { it["href"][%r{\A/account/bots/(\d+)/edit\z}, 1]&.to_i }
            .select { |bot| page.at_css("a[href='/account/bots/#{bot}/edit']")&.ancestors("li")&.first&.at_css("strong")&.text == name }.max
          id or raise Changed, "bots page"
          key = page.css("input[readonly]").filter_map { it["value"][%r{/rooms/\d+/(#{id}-[A-Za-z0-9]+)/messages}, 1] }.first
          key or raise Error, "Campfire made the bot but shows no key: it is in no open room. Add it to a room and paste its key by hand."
        end
      end

      # The rooms the bot is in, but not its direct ones, by number: { 1 => "All Talk" }.
      # The bots page names each in its legend and numbers it in its post command.
      def rooms_of(id)
        signed_in do
          page = get("account/bots", what: "bots page")
          bot = page.at_css("a[href='/account/bots/#{Integer(id)}/edit']")&.ancestors("li")&.first
          bot or raise Error, "Campfire has no bot #{id}: it was removed there."
          bot.css("fieldset").to_h do |room|
            number = room.at_css("input[readonly]")&.[]("value").to_s[%r{/rooms/(\d+)/#{Integer(id)}-}, 1]
            name = room.at_css("legend")&.text.to_s.squish
            raise Changed, "bots page" unless number && name.present?
            [ number.to_i, name ]
          end
        end
      end

      # Campfire calls the bot at a new address.
      def update_webhook(id, name:, webhook_url:)
        signed_in do
          form = form_on("account/bots/#{id}/edit", action: "/account/bots/#{id}", method: "patch", what: "bot's settings", fields: %w[ user[name] user[webhook_url] ])
          submit form, "user[name]" => name, "user[webhook_url]" => webhook_url, expect: "/account/bots"
        end
      end

      # The bot leaves every room and its key stops working.
      def deactivate_bot(id)
        signed_in do
          response = request(Net::HTTP::Get, "account/bots/#{id}/edit")
          return if response.is_a?(Net::HTTPNotFound) # already gone
          form = form_in(page_of(response, "bot's settings"), action: "/account/bots/#{id}", method: "delete", what: "bot's delete button")
          submit form, expect: "/account/bots"
        end
      end

      private
        # Each change is one Campfire session, ended after, so none lingers.
        def signed_in
          sign_in
          yield
        ensure
          sign_out
        end

        def sign_out
          request(Net::HTTP::Post, "session", "_method" => "delete") if @cookies.key?("session_token")
        rescue Error
          # The session ends with Campfire's own expiry instead.
        ensure
          @cookies.clear
        end

        def sign_in
          form = form_on("session/new", action: "/session", what: "sign-in form", fields: %w[ email_address password ])
          response = submit(form, "email_address" => @email, "password" => @password, expect: nil)
          raise Error, "Campfire refused the administrator's email and password." if response.is_a?(Net::HTTPUnauthorized)
          raise Changed, "sign-in" unless response.is_a?(Net::HTTPRedirection) && @cookies.key?("session_token")
        end

        def get(path, what:) = page_of(request(Net::HTTP::Get, path), what)

        def page_of(response, what)
          raise Error, "Campfire's #{what} needs an administrator (#{response.code})." if response.is_a?(Net::HTTPForbidden)
          raise Changed, what unless response.is_a?(Net::HTTPOK)
          Nokogiri::HTML5(response.body)
        end

        def form_on(path, **options) = form_in(get(path, what: options[:what]), **options)

        # The form posting to `action`, overriding to `method` when not POST,
        # with every field named in `fields`.
        def form_in(page, action:, what:, method: nil, fields: [])
          form = page.css("form[method=post]").find do |candidate|
            # Campfire writes some actions as full URLs, on whatever host it was asked by.
            URI(candidate["action"].to_s).path == action && candidate.at_css("input[name=_method]")&.[]("value") == method
          end
          raise Changed, what unless form && fields.all? { form.at_css("[name='#{it}']") }
          form
        end

        # The form's hidden fields (a CSRF token, _method), then the values.
        def submit(form, values = {})
          expect = values.delete(:expect)
          hidden = form.css("input[type=hidden][name]").to_h { [ it["name"], it["value"].to_s ] }
          response = request(Net::HTTP::Post, URI(form["action"]).path.delete_prefix("/"), hidden.merge(values))
          if expect && !(response.is_a?(Net::HTTPRedirection) && URI(response["location"].to_s).path == expect)
            raise Error, "Campfire refused (#{response.code})." if response.is_a?(Net::HTTPClientError) && !response.is_a?(Net::HTTPUnprocessableEntity)
            raise Changed, "answer to #{form["action"]}"
          end
          response
        end

        def request(kind, path, form = nil)
          uri = URI.join(@base, path)
          message = kind.new(uri)
          message["Cookie"] = @cookies.map { "#{_1}=#{_2}" }.join("; ") if @cookies.any?
          message["User-Agent"] = "durable-assistants"
          if form
            # Campfire guards its forms by the browser's Sec-Fetch-Site, not a
            # token, and behind TLS (assume_ssl) refuses a post without it.
            message["Sec-Fetch-Site"] = "same-origin"
            message.set_form_data(form)
          end
          response = Net::HTTP.start(uri.host, uri.port, nil, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(message) }
          Array(response.get_fields("set-cookie")).each { |cookie| name, value = cookie.split(";").first.split("=", 2); @cookies[name] = value }
          response
        rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => problem
          raise Error, "Could not reach Campfire (#{problem.class.name.demodulize})."
        end
    end
  end
end
