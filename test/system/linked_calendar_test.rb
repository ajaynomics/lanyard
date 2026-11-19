require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# The linked calendar's form in a browser (docs/calendar.md): typed field by
# field and sent by its button, a refusal keeping what was typed, and Unlink.
class LinkedCalendarSystemTest < ApplicationSystemTestCase
  include AgentTestHelper
  include PassboltTestHelper

  setup do
    install_fake_passbolt(name: "Family calendar", uri: "https://caldav.example.com")
    sign_in_via_ajent
    @agent = User.find_by!(oidc_sub: "42").agents.sole # tenancy-ok: the test reads the person it signed in
  end
  teardown do
    remove_fake_passbolt
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "a person types the three fields, links the calendar, is told what was wrong, and unlinks it" do
    visit agent_channels_path(@agent)
    within("#linked_calendar") do
      fill_in "Server", with: "https://caldav.example.com"
      fill_in "Calendar", with: "https://elsewhere.example/family/"
      fill_in "Saved sign-in", with: "Family calendar"
      click_on "Link calendar"
      assert_selector "[role=alert]", text: "must be on the server named"
      assert_field "Server", with: "https://caldav.example.com"
      assert_field "Saved sign-in", with: "Family calendar"

      fill_in "Calendar", with: "/123/calendars/family/"
      click_on "Link calendar"
      assert_text "reads and changes this one calendar"
    end
    assert @agent.reload.linked_calendar?

    within("#linked_calendar") { click_on "Unlink" }
    within("dialog#confirm[open]") { click_on "Unlink" }
    within("#linked_calendar") { assert_no_button "Unlink" }
    assert_field "Server", with: ""
    assert_nil @agent.reload.linked_calendar_server
  end
end
