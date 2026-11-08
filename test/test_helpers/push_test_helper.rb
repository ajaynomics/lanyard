# The install's Web Push keys for a test, made fresh (no real key is kept
# anywhere), and a browser's subscription with keys a browser would make.
# Push services are stubbed with WebMock: nothing leaves the machine.
module PushTestHelper
  VAPID = WebPush.generate_key
  ENDPOINT = "https://fcm.googleapis.com/fcm/send/synthetic-robin".freeze
  ANDROID_CHROME = "Mozilla/5.0 (Linux; Android 16) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0 Mobile Safari/537.36".freeze

  def install_push_settings
    settings = Rails.application.config.x.web_push
    @previous_push = settings.dup
    settings.merge!(public_key: VAPID.public_key, private_key: VAPID.private_key, subject: "mailto:operator@example.com")
  end

  def remove_push_settings
    Rails.application.config.x.web_push.replace(@previous_push) if @previous_push
  end

  # What a browser's PushSubscription#toJSON gives: its push service's
  # address, its P-256 public key and a 16-byte secret, base64url.
  def browser_keys
    point = OpenSSL::PKey::EC.generate("prime256v1").public_key.to_bn.to_s(2)
    { p256dh_key: Base64.urlsafe_encode64(point, padding: false), auth_key: Base64.urlsafe_encode64(SecureRandom.random_bytes(16), padding: false) }
  end

  def subscribe(user, endpoint: ENDPOINT, user_agent: ANDROID_CHROME)
    user.push_subscriptions.create!(endpoint: endpoint, user_agent: user_agent, **browser_keys)
  end
end
