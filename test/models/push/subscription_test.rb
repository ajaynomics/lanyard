require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/push_test_helper"

# A browser where the person turned notifications on: only a real push
# service's address is kept, a notice reaches it encrypted and signed, and a
# push service that says the browser is gone takes the row with it.
class Push::SubscriptionTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PushTestHelper

  setup do
    install_push_settings
    @robin = create_user(name: "Robin")
  end
  teardown { remove_push_settings }

  test "only a browser's push service, over https, is kept as an address" do
    assert subscribe(@robin).persisted?
    [ "https://updates.push.services.mozilla.com/wpush/v2/abc", "https://web.push.apple.com/QH4", "https://wns2-db5p.notify.windows.com/w/?token=x" ]
      .each { assert @robin.push_subscriptions.new(endpoint: it, **browser_keys).valid?, it }
    [ "http://fcm.googleapis.com/fcm/send/x", "https://fcm.googleapis.com.example.com/x", "https://127.0.0.1/x",
      "https://example.com/fcm.googleapis.com", "https://fcm.googleapis.com:8443/x", "https://user@fcm.googleapis.com/x", "not a url" ]
      .each { assert_not @robin.push_subscriptions.new(endpoint: it, **browser_keys).valid?, it }
  end

  test "a device is named for Settings by its browser and system" do
    {
      ANDROID_CHROME => "Chrome on Android",
      "Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1" => "Safari on iPhone",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:150.0) Gecko/20100101 Firefox/150.0" => "Firefox on Mac",
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0 Safari/537.36 Edg/150.0" => "Edge on Windows",
      "" => "A browser"
    }.each { |agent, device| assert_equal device, Push::Subscription.new(user_agent: agent).device }
  end

  test "a notice goes to the push service, encrypted and signed with the install's key" do
    subscription = subscribe(@robin)
    stub_request(:post, ENDPOINT).to_return(status: 201)

    assert_equal :sent, subscription.deliver({ kind: "reply", title: "Iris", body: "Booked.", url: "/conversations/1", tag: "conversation-1", badge: 0 }).outcome

    assert_requested(:post, ENDPOINT) do |request|
      request.headers["Content-Encoding"] == "aes128gcm" && request.headers["Ttl"] == 1.day.to_i.to_s && request.headers["Urgency"] == "high" &&
        request.headers["Authorization"].start_with?("vapid t=") && request.headers["Authorization"].include?("k=#{VAPID.public_key.delete("=")}") &&
        request.body.bytesize.positive? && !request.body.include?("Booked")
    end
    assert subscription.reload.persisted?
  end

  test "a push service that says the browser is gone (410) or never was (404) takes the row; any other failure keeps it" do
    gone = subscribe(@robin)
    unknown = subscribe(@robin, endpoint: "#{ENDPOINT}-2")
    down = subscribe(@robin, endpoint: "#{ENDPOINT}-3")
    stub_request(:post, ENDPOINT).to_return(status: 410)
    stub_request(:post, "#{ENDPOINT}-2").to_return(status: 404)
    stub_request(:post, "#{ENDPOINT}-3").to_return(status: 503)

    deliveries = [ gone, unknown, down ].map { it.deliver({ title: "Iris" }) }
    assert_equal [ [ :expired, "HTTP 410" ], [ :expired, "HTTP 404" ], [ :failed, "HTTP 503" ] ], deliveries.map { [ it.outcome, it.reason ] }

    assert_equal [ down ], @robin.push_subscriptions.reload.to_a
  end

  # Apple refuses every push signed with anything else ("BadJwtToken").
  test "push is on only with both keys and a subject that is a mailto: or https: address" do
    assert Push.configured?
    { "https://ops.example.com" => true, "mailto:ops@example.com" => true, "mailto:Ops <ops@example.com>" => false,
      "ops@example.com" => false, "http://ops.example.com" => false, "" => false }.each do |subject, on|
      with_setting(:web_push, :subject, subject) { assert_equal on, Push.configured?, subject }
    end
    with_setting(:web_push, :private_key, nil) { assert_not Push.configured? }
  end

  test "the delivery job sends one notice to each of the person's devices, and none to anyone else's" do
    subscribe(@robin)
    subscribe(@robin, endpoint: "#{ENDPOINT}-tablet")
    subscribe(create_user(name: "Sam"), endpoint: "#{ENDPOINT}-sam")
    stub_request(:post, %r{\Ahttps://fcm.googleapis.com/}).to_return(status: 201)

    Push::DeliveryJob.perform_now(@robin, { title: "Iris" })

    assert_requested :post, ENDPOINT, times: 1
    assert_requested :post, "#{ENDPOINT}-tablet", times: 1
    assert_not_requested :post, "#{ENDPOINT}-sam"
  end
end
