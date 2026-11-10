require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/push_test_helper"

# Settings, You: which kinds of notification the person wants, all on until
# they turn one off, each switch saved as it changes.
class Settings::NotificationsControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PushTestHelper

  setup do
    install_push_settings
    sign_in_via_ajent(name: "Robin")
    @robin = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
  end
  teardown { remove_push_settings }

  test "You shows the three switches, all on at first, and each saves on its own" do
    get settings_account_path
    %w[ push_messages push_needs_you push_errors ].each do |choice|
      assert_select "form[action=?][data-controller=autosave] input##{choice}[role=switch][name=?][checked]", settings_notifications_path, "user[#{choice}]"
    end

    patch settings_notifications_path, params: { user: { push_errors: "0" } }
    assert_redirected_to settings_account_path
    assert_equal [ true, true, false ], @robin.reload.values_at(:push_messages, :push_needs_you, :push_errors)
    get settings_account_path
    assert_select "input#push_errors[checked]", count: 0

    patch settings_notifications_path, params: { user: { push_errors: "1", push_messages: "0" } }
    assert_equal [ false, true, true ], @robin.reload.values_at(:push_messages, :push_needs_you, :push_errors)
  end

  test "only the person's own choices, and only these three, are changed" do
    sam = create_user(name: "Sam")
    patch settings_notifications_path, params: { user: { push_errors: "0", name: "Mallory", id: sam.id } }
    assert_equal [ "Robin", false ], @robin.reload.values_at(:name, :push_errors)
    assert sam.reload.push_errors
  end

  test "without the install's keys the choices aren't offered" do
    with_setting(:web_push, :public_key, nil) { get settings_account_path }
    assert_select "#notify_about_title", count: 0
  end
end
