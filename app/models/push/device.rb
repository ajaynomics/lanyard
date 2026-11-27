# One iPhone where the phone app turned notifications on (docs/native-app.md,
# "Notifications"): the device token Apple's push service gave it, and whether
# that token is for Apple's production service (TestFlight and the App Store)
# or its sandbox (a development build), and which session posted it, so its own
# iPhone's Settings can tell it from another's. Apple says when the app is gone from
# the device; the row goes then. Other failures leave it.
class Push::Device < ApplicationRecord
  ENVIRONMENTS = DurableAssistants::Apns::HOSTS.keys

  # Apple's push service; a test hands in its own.
  class_attribute :apns, default: DurableAssistants::Apns

  belongs_to :user

  # The phone app's Settings tab says whether this iPhone's are on (SettingsHelper#notifications_status).
  broadcasts_refreshes_to ->(device) { [ device.user, :settings ] }

  validates :token, format: { with: /\A\h{32,200}\z/ }
  validates :environment, inclusion: { in: ENVIRONMENTS }

  normalizes :token, with: -> { it.to_s.strip.downcase }

  # The device whose token this signed-in session posted, from Turn on on its
  # page or from the app itself, which sends the web view's cookies: this
  # iPhone, not another of the person's. Kept as the session id's private
  # digest, never the id or anything that could sign in.
  def self.this_session(session) = (digest = digest(session)) && find_by(session_digest: digest)

  def self.digest(session) = session.id&.private_id

  # What iOS allows on this iPhone, as the app says each time it comes to the
  # front (PushRegistration): notifications turned off in the iPhone's Settings
  # make it refused, turned on again not. The report Rails receives last wins:
  # the phone's clock can be wrong, so Rails never orders by it.
  def reported(refused:)
    update!(refused: refused)
  end

  # One notice, as Apple shows it, with where a tap opens: the card itself
  # when it is one, else the thread. Says what became of it, as
  # Push::Subscription#deliver does.
  def deliver(notice)
    response = apns.deliver(token: token, environment: environment, payload: payload(notice), collapse_id: notice[:tag],
      priority: priority?(notice) ? 10 : 5)
    if response.sent?
      Push::Subscription::Delivery.new(:sent, nil)
    elsif response.gone?
      destroy
      Push::Subscription::Delivery.new(:expired, response.reason)
    else
      # Neither the token nor the notice: only how Apple answered.
      Rails.logger.warn("APNs push failed: #{response.status} (#{response.reason})")
      Push::Subscription::Delivery.new(:failed, response.reason || "HTTP #{response.status}")
    end
  end

  private
    # The category names the notice's buttons, which the phone and the Watch
    # register (#78); the ids and the card's version are what an answer from
    # them posts. Ids and a digest only, never a card's words. A priority
    # notice sounds and is time-sensitive, which the app's entitlement lets
    # through a Focus; a regular one is passive, without a sound or a banner,
    # straight to Notification Centre, where the thread-id groups it with its
    # thread's others (#82).
    def payload(notice)
      priority = priority?(notice)
      { aps: { alert: { title: notice[:title], body: notice[:body] }.compact, badge: notice[:badge], sound: ("default" if priority),
               "interruption-level": priority ? "time-sensitive" : "passive", "thread-id": notice[:tag], category: notice[:category] }.compact,
        url: notice[:approval_url] || notice[:url],
        **notice.slice(:conversation_id, :invocation_id, :version) }.compact
    end

    # One queued before levels were has none, and is regular.
    def priority?(notice) = notice[:level] == "priority"
end
