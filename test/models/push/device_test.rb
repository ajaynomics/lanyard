require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The phone app's notifications, through Apple's push service: off until the
# install has every APNs setting, then each notice to each of the person's
# iPhones, opening the card itself where it is one. A device Apple says is
# gone goes; any other failure leaves it.
class Push::DeviceTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ActiveJob::TestHelper

  APNS = { key_id: "KEY1234567", team_id: "TEAM123456", private_key: OpenSSL::PKey::EC.generate("prime256v1").to_pem, topic: "org.example.app" }.freeze

  setup do
    @robin = create_user(name: "Robin")
    @device = @robin.push_devices.create!(token: "ab" * 32, environment: "sandbox")
  end

  test "with no APNs key nothing is sent, and a person with only the app is not reachable" do
    assert_not Push.native?
    assert_not Push.reaches?(@robin)
    Push.deliver(@robin, kind: "reply", title: "Iris", body: "Booked.", url: "/conversations/1", tag: "conversation-1")
    assert_empty enqueued_jobs.select { it["job_class"] == "Push::DeliveryJob" }

    with_apple(->(**) { flunk "nothing goes to Apple without a key" }) do
      Push::DeliveryJob.perform_now(@robin, { title: "Iris", url: "/" })
    end
  end

  test "with one, each notice goes to Apple with the badge, and a tap opens the card itself" do
    sent = []
    with_apns do
      assert Push.reaches?(@robin)
      with_apple(->(**request) { sent << request; DurableAssistants::Apns::Response.new(200, nil) }) do
        perform_enqueued_jobs do
          Push.deliver(@robin, kind: "needs_you", title: "Iris needs you", body: "Allow forget note?", url: "/conversations/1",
            approval_url: "/approvals/7", tag: "conversation-1")
        end
      end
    end

    request = sent.sole
    assert_equal [ "ab" * 32, "sandbox", "conversation-1" ], request.values_at(:token, :environment, :collapse_id)
    assert_equal({ aps: { alert: { title: "Iris needs you", body: "Allow forget note?" }, badge: 0, sound: "default",
                          "interruption-level": "time-sensitive", "thread-id": "conversation-1" },
                   url: "/approvals/7" }, request[:payload])
  end

  # #82: a priority notice sounds, reaches the Watch and breaks through a
  # Focus as time-sensitive, at Apple's immediate priority. A regular one is
  # passive: no sound and no banner, straight to Notification Centre, grouped
  # with its thread's others, sent when it suits the phone's battery. One
  # from before levels is regular.
  test "a priority notice sounds and is time-sensitive; a regular one goes quietly to Notification Centre" do
    sent = []
    with_apns do
      with_apple(->(**request) { sent << request; DurableAssistants::Apns::Response.new(200, nil) }) do
        @device.deliver({ level: "priority", title: "Iris needs you", body: "Allow forget note?", url: "/", tag: "conversation-1", badge: 1 })
        @device.deliver({ level: "regular", title: "Iris", body: "Booked.", url: "/", tag: "conversation-1", badge: 1 })
        @device.deliver({ title: "Iris", body: "Booked.", url: "/", tag: "conversation-1", badge: 1 })
      end
    end

    priority, regular, unlevelled = sent
    assert_equal({ alert: { title: "Iris needs you", body: "Allow forget note?" }, badge: 1, sound: "default",
                   "interruption-level": "time-sensitive", "thread-id": "conversation-1" }, priority[:payload][:aps])
    assert_equal({ alert: { title: "Iris", body: "Booked." }, badge: 1, "interruption-level": "passive", "thread-id": "conversation-1" },
      regular[:payload][:aps])
    assert_equal regular[:payload], unlevelled[:payload]
    assert_equal [ 10, 5, 5 ], sent.map { it[:priority] }
  end

  test "Apple is asked to send a notice at the priority it is given" do
    posted = []
    with_apns do
      DurableAssistants::Apns.singleton_class.alias_method :real_post, :post
      DurableAssistants::Apns.define_singleton_method(:post) { |*request| posted << request; DurableAssistants::Apns::Response.new(200, nil) }
      DurableAssistants::Apns.deliver(token: "ab" * 32, environment: "sandbox", payload: {}, priority: 5)
      DurableAssistants::Apns.deliver(token: "ab" * 32, environment: "sandbox", payload: {})
    ensure
      DurableAssistants::Apns.singleton_class.alias_method :post, :real_post
    end
    assert_equal %w[ 5 10 ], posted.map { it[2]["apns-priority"] }
  end

  # The phone and the Watch show a card's buttons, or Reply, from its
  # category, and answer with the ids and the card's version (#78).
  test "a notice's category goes in aps, its ids and the card's version beside it" do
    sent = []
    with_apns do
      with_apple(->(**request) { sent << request; DurableAssistants::Apns::Response.new(200, nil) }) do
        @device.deliver({ kind: "needs_you", title: "Iris needs you", body: "Allow forget note?", url: "/conversations/1", approval_url: "/approvals/7",
          tag: "conversation-1", badge: 1, conversation_id: 1, invocation_id: 7, category: "APPROVAL", version: "v" * 64 })
      end
    end

    payload = sent.sole[:payload]
    assert_equal "APPROVAL", payload[:aps][:category]
    assert_equal [ 1, 7, "v" * 64, "/approvals/7" ], payload.values_at(:conversation_id, :invocation_id, :version, :url)
  end

  test "a device Apple says is gone is forgotten; a failure on the way is not" do
    with_apns do
      with_apple(->(**) { DurableAssistants::Apns::Response.new(500, "InternalServerError") }) do
        assert_equal :failed, @device.deliver({ title: "Iris", url: "/" }).outcome
      end
      assert Push::Device.exists?(@device.id) # tenancy-ok: test checks the one row it made

      with_apple(->(**) { DurableAssistants::Apns::Response.new(410, "Unregistered") }) do
        assert_equal :expired, @device.deliver({ title: "Iris", url: "/" }).outcome
      end
      assert_not Push::Device.exists?(@device.id) # tenancy-ok: test checks the one row it made
    end
  end

  test "a token is the hex iOS gives, for one of Apple's two services" do
    assert_not @robin.push_devices.build(token: "<script>").valid?
    assert_not @robin.push_devices.build(token: "cd" * 32, environment: "elsewhere").valid?
    assert @robin.push_devices.build(token: " #{"CD" * 32} ").tap(&:validate).then { it.valid? && it.token == "cd" * 32 }
  end

  test "Apple's provider token is an ES256 JWT of the key id and team, signed with the key, and kept for under an hour" do
    with_apns do
      now = Time.current
      token = DurableAssistants::Apns.bearer(now: now)
      header, claims, signature = token.split(".")
      assert_equal({ "alg" => "ES256", "kid" => "KEY1234567" }, JSON.parse(Base64.urlsafe_decode64(header)))
      assert_equal({ "iss" => "TEAM123456", "iat" => now.to_i }, JSON.parse(Base64.urlsafe_decode64(claims)))

      raw = Base64.urlsafe_decode64(signature)
      assert_equal 64, raw.bytesize
      der = OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[0, 32], 2)), OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[32, 32], 2)) ]).to_der
      assert OpenSSL::PKey::EC.new(APNS[:private_key]).verify("SHA256", der, "#{header}.#{claims}")

      assert_equal token, DurableAssistants::Apns.bearer(now: now + 49.minutes)
      assert_not_equal token, DurableAssistants::Apns.bearer(now: now + 51.minutes)
    end
  end

  private
    # Apple's push service, answering as the test says.
    def with_apple(answer)
      Push::Device.apns = Struct.new(:deliver_with) { def deliver(**request) = deliver_with.(**request) }.new(answer)
      yield
    ensure
      Push::Device.apns = DurableAssistants::Apns
    end

    def with_apns(&block)
      APNS.reduce(block) { |inner, (key, value)| -> { with_setting(:apns, key, value, &inner) } }.call
    end
end
