require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/passbolt_test_helper"

class Agent::CalendarServerTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper

  setup { @agent = create_user(name: "Alice").agents.sole }
  teardown { remove_fake_passbolt }

  test "it keeps the calendar home's address and a vault entry's name, never a password" do
    server = @agent.create_calendar_server!(url: " https://dav.example.com/dav/calendars/desk/ ", vault_entry: "  Desk   calendar ")
    assert_equal [ "https://dav.example.com/dav/calendars/desk/", "Desk calendar" ], server.values_at(:url, :vault_entry)
    assert_not_includes Agent::CalendarServer.column_names.join(" "), "password"
  end

  test "its address is one https calendar home, with no sign-in, query, fragment or step up" do
    [ "http://dav.example.com/desk/", "https://dav.example.com", "https://dav.example.com/", "https://user:pw@dav.example.com/desk/",
      "https://dav.example.com/desk/?x=1", "https://dav.example.com/desk/#a", "https://dav.example.com/desk/../other/",
      "https://dav.example.com/desk/%2e%2e/other/", "dav.example.com/desk/", "https:///desk/" ].each do |url|
      server = Agent::CalendarServer.new(agent: @agent, url: url, vault_entry: "Desk calendar")
      assert_not server.valid?, "#{url} was taken"
      assert server.errors[:url].any?, url
    end
  end

  test "it needs the vault entry's name, at most 200 characters, and is one per agent" do
    assert_not Agent::CalendarServer.new(agent: @agent, url: "https://dav.example.com/desk/").valid?
    assert_not Agent::CalendarServer.new(agent: @agent, url: "https://dav.example.com/desk/", vault_entry: "x" * 201).valid?
    @agent.create_calendar_server!(url: "https://dav.example.com/desk/", vault_entry: "Desk calendar")
    assert_includes Agent::CalendarServer.new(agent: @agent, url: "https://dav.example.com/desk/", vault_entry: "x").tap(&:valid?).errors[:agent_id], "has already been taken"
  end

  test "it is used only where the agent can read the vault, and goes with its agent" do
    @agent.create_calendar_server!(url: "https://dav.example.com/desk/", vault_entry: "Desk calendar")
    assert_not @agent.calendar?
    install_fake_passbolt(name: "Desk calendar", uri: "https://dav.example.com")
    assert @agent.reload.calendar?
    assert_empty passbolt_calls
    @agent.destroy!
    assert_not Agent::CalendarServer.exists?(agent_id: @agent.id) # tenancy-ok: the deleted agent's own row
  end
end
