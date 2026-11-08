require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/push_test_helper"

# Notifications on this browser, from Settings (You): a subscription is the
# signed-in person's, another person's cannot be removed, and the row and
# its switch show only where the install has keys.
class Push::SubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PushTestHelper

  setup do
    install_push_settings
    sign_in_via_ajent(name: "Robin")
    @robin = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
  end
  teardown { remove_push_settings }

  test "turning notifications on keeps this browser's address for the person, once, naming the device" do
    keys = browser_keys
    2.times do
      post push_subscriptions_path, params: { push_subscription: { endpoint: ENDPOINT, **keys } }, as: :json,
        headers: { "User-Agent" => ANDROID_CHROME }
      assert_response :created
    end

    subscription = @robin.push_subscriptions.sole
    assert_equal [ ENDPOINT, keys[:p256dh_key], "Chrome on Android" ], [ subscription.endpoint, subscription.p256dh_key, subscription.device ]
  end

  test "an address that is not a browser's push service is refused" do
    post push_subscriptions_path, params: { push_subscription: { endpoint: "https://internal.example.com/hook", **browser_keys } }, as: :json
    assert_response :unprocessable_entity
    assert_empty @robin.push_subscriptions.reload
  end

  test "a browser someone else turned notifications on in notifies only the person turning them on now" do
    sam = create_user(name: "Sam")
    subscribe(sam)
    post push_subscriptions_path, params: { push_subscription: { endpoint: ENDPOINT, **browser_keys } }, as: :json
    assert_response :created
    assert_empty sam.push_subscriptions.reload
    assert_equal [ ENDPOINT ], @robin.push_subscriptions.pluck(:endpoint)
  end

  test "Remove takes off one of the person's own devices; another person's is not found" do
    own = subscribe(@robin)
    delete push_subscription_path(own), as: :json
    assert_response :no_content
    assert_empty @robin.push_subscriptions.reload

    tablet = subscribe(@robin, endpoint: "#{ENDPOINT}-tablet")
    delete push_subscription_path(tablet)
    assert_redirected_to settings_account_path

    sams = subscribe(create_user(name: "Sam"), endpoint: "#{ENDPOINT}-sam")
    delete push_subscription_path(sams)
    assert_response :not_found
    assert sams.reload.persisted?
  end

  test "You lists the person's devices with Remove, and the switch, only where the install has keys" do
    subscribe(@robin)
    get settings_account_path
    assert_select "section#notifications[data-controller=notifications][data-turbo-permanent]" do
      assert_select "[data-notifications-key-value=?]", VAPID.public_key
      assert_select "input#notifications_switch[role=switch]"
    end
    assert_select "#devices_title", "Robin's devices"
    assert_select "li[data-push-endpoint=?]", ENDPOINT, text: /Chrome on Android\s+Added/ do
      assert_select "form[action=?] button[aria-label=?]", push_subscription_path(@robin.push_subscriptions.sole), "Remove Chrome on Android", text: "Remove"
    end

    with_setting(:web_push, :public_key, nil) { get settings_account_path }
    assert_select "#notifications", count: 0
    assert_select "#devices_title", count: 0
    post push_subscriptions_path, params: { push_subscription: { endpoint: "#{ENDPOINT}-2", **browser_keys } }, as: :json
    assert_response :created, "keys are back after the block"
    with_setting(:web_push, :private_key, nil) do
      post push_subscriptions_path, params: { push_subscription: { endpoint: "#{ENDPOINT}-3", **browser_keys } }, as: :json
    end
    assert_response :not_found
  end
end
