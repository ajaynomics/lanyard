require "async/websocket/adapters/rails"

# The conversation's screen: a page that shows its Sprite's desktop through noVNC, and
# the websocket that page opens to this same address. Rails relays the
# websocket to the sidecar, which wakes the Sprite and pipes it to the
# screen's websockify (docs/design/CONTRACT.md). You watch and type while the
# conversation works.
class Conversations::ScreensController < ApplicationController
  def show
    @conversation = Current.user.conversations.find(params[:conversation_id])
    raise ActiveRecord::RecordNotFound unless @conversation.screen?
    unless Async::WebSocket::Adapters::Rack.websocket?(request.env)
      @waking_from_cold = @conversation.waking_from_cold?
      return
    end
    # A websocket carries the person's cookies from any page that opens it.
    return head :forbidden unless request.origin == app_origin

    self.response = Async::WebSocket::Adapters::Rails.open(request, protocols: %w[ binary ]) do |browser|
      @conversation.screen { |computer| relay(browser, computer) }
    rescue DurableAssistants::PiDurable::Client::Error
      browser.close
    end
  end

  private
    def app_origin
      URI(DurableAssistants.config(:app, :url).to_s).then { "#{it.scheme}://#{it.host}#{":#{it.port}" unless it.port == it.default_port}" }
    end

    def relay(browser, computer)
      upstream = Async do
        while (message = computer.read)
          browser.write(message)
          browser.flush
        end
      ensure
        browser.close
      end
      while (message = browser.read)
        computer.write(message)
        computer.flush
      end
    ensure
      upstream&.stop
    end
end
