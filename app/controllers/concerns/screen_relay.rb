require "async/websocket/adapters/rails"

# Pipes a browser's websocket to a conversation's screen and back
# (Conversation#screen), for a signed-in person's screen page and for a
# visitor's one-time link (ScreenPass). Given a block, it asks it every few
# seconds whether to go on, and cuts the screen the moment it says no.
module ScreenRelay
  CHECK_EVERY = 3

  private
    def app_origin
      URI(DurableAssistants.config(:app, :url).to_s).then { "#{it.scheme}://#{it.host}#{":#{it.port}" unless it.port == it.default_port}" }
    end

    def websocket? = Async::WebSocket::Adapters::Rack.websocket?(request.env)

    def open_screen(conversation, retained: false, &live)
      self.response = Async::WebSocket::Adapters::Rails.open(request, protocols: %w[ binary ]) do |browser|
        conversation.screen(**(retained ? { retained: true } : {})) { |computer| relay(browser, computer, &live) }
      rescue DurableAssistants::PiDurable::Client::Error
        browser.close
      end
    end

    def relay(browser, computer, check_every: CHECK_EVERY, &live)
      Sync do |reader|
        upstream = reader.async do
          while (message = computer.read)
            browser.write(message)
            browser.flush
          end
        ensure
          browser.close
        end
        watch = reader.async do
          sleep check_every while live.call
          browser.close
          upstream.stop
          reader.stop
        end if live
        while (message = browser.read)
          computer.write(message)
          computer.flush
        end
      ensure
        upstream&.stop
        watch&.stop
      end
    end
end
