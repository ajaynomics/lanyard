# One browser where the person turned notifications on: the address its push
# service gave it and the keys that encrypt a notice to it alone. The push
# service deletes the address when the browser no longer wants it, and says
# so with a 404 or 410; the row goes then. Other failures leave it, since a
# push service that is down today is up tomorrow.
class Push::Subscription < ApplicationRecord
  # Only the browsers' own push services: the address is the person's to
  # give, and the server posts to it, so it must not be able to name
  # anything else (another site, a machine inside the host).
  PUSH_SERVICES = %w[ fcm.googleapis.com jmt17.google.com updates.push.services.mozilla.com web.push.apple.com notify.windows.com ].freeze
  # A notice that cannot reach a device within a day is no longer news.
  TTL = 1.day.to_i

  belongs_to :user

  validates :endpoint, presence: true, length: { maximum: 2_048 }
  validates :p256dh_key, :auth_key, presence: true, length: { maximum: 256 }
  validate :endpoint_is_a_push_service

  before_validation { self.user_agent = user_agent.to_s.first(512) }

  # Sends one notice, encrypted end to end by Web Push: the push service
  # carries it without reading it.
  def deliver(payload)
    WebPush.payload_send(message: payload.to_json, endpoint: endpoint, p256dh: p256dh_key, auth: auth_key,
      vapid: Push.vapid, ttl: TTL, urgency: "high", open_timeout: 5, read_timeout: 10)
  rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
    destroy
  rescue WebPush::Error, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, SocketError => error
    # Not the address, which is the device's to keep private; only whose service failed.
    Rails.logger.warn("Push to #{host} failed: #{error.class.name}")
  end

  # The device in words, for Settings to list: "Chrome on Android".
  def device
    browser = case user_agent
    when /Edg\//i then "Edge"
    when /SamsungBrowser/i then "Samsung Internet"
    when /Firefox|FxiOS/i then "Firefox"
    when /Chrome|CriOS|Chromium/i then "Chrome"
    when /Safari/i then "Safari"
    end
    system = case user_agent
    when /iPhone/i then "iPhone"
    when /iPad/i then "iPad"
    when /Android/i then "Android"
    when /Mac OS X|Macintosh/i then "Mac"
    when /Windows/i then "Windows"
    when /CrOS/i then "ChromeOS"
    when /Linux/i then "Linux"
    end
    [ browser, system ].compact.join(" on ").presence || "A browser"
  end

  def host
    URI(endpoint).host
  rescue URI::InvalidURIError
    nil
  end

  private
    def endpoint_is_a_push_service
      uri = URI(endpoint.to_s)
      return if uri.scheme == "https" && uri.port == 443 && uri.userinfo.nil? &&
        PUSH_SERVICES.any? { uri.host.to_s.downcase == it || uri.host.to_s.downcase.end_with?(".#{it}") }
      errors.add(:endpoint, "is not a browser's push service")
    rescue URI::InvalidURIError
      errors.add(:endpoint, "is not a browser's push service")
    end
end
