require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/caldav_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

class EventOnlyCalendarTest < ActionDispatch::IntegrationTest
  include AgentTestHelper, CaldavTestHelper, PassboltTestHelper

  SERVER = "https://calendar.example.com"
  WORK = "#{SERVER}/calendars/work/"
  FIELD = "Field calendar sign-in"
  TAG = '"etag-one"'

  setup do
    install_fake_passbolt(name: FIELD, uri: SERVER)
    @owner = create_user(name: "Owner")
    @agent = @owner.agents.sole
    @agent.create_calendar_server!(vault_entry: FIELD, collection_urls: "#{WORK}\n#{SERVER}/team/second/\n")
    @client = @agent.reload.caldav
    @get = stub_request(:get, "#{WORK}example.ics").to_return(status: 200, headers: { "ETag" => TAG }, body: event.to_ical)
  end

  teardown do
    remove_fake_passbolt
    remove_caldav
  end

  test "each pin is an event list; unknown lists, tasks and ambiguous item names never make a request" do
    assert_equal [ [ "work", [ "events" ] ], [ "second", [ "events" ] ] ], @client.lists.map { it.values_at(:list, :kinds) }
    assert_not @agent.alarm_calendar?
    assert_empty Agent::Alarm.due(@agent, from: 1.day.ago, to: Time.current)
    [ -> { @client.items("unknown", "events") }, -> { @client.items("work", "tasks") },
      -> { @client.item("work", "x%2fexample") }, -> { @client.item("work", "../../principal") } ].each do |call|
      assert_equal 403, assert_raises(DurableAssistants::Caldav::Error, &call).status
    end
    assert_not_requested @get
    assert_not_includes passbolt_calls, "get resource"
  end

  test "the restricted account never falls back to the install calendar" do
    install_caldav(username: "agent-1", password: "app-password")
    @agent.update!(caldav_username: "agent-1", caldav_password: "app-password")
    remove_fake_passbolt
    assert_equal %w[ work second ], @agent.reload.caldav.lists.pluck(:list)
    assert_equal 403, assert_raises(DurableAssistants::Caldav::Error) { @agent.caldav.items("calendar", "events") }.status
    assert_not_requested :any, /#{Regexp.escape(CaldavTestHelper::URL)}/
  end

  test "the existing vault hostname check still refuses another host before HTTP" do
    remove_fake_passbolt
    install_fake_passbolt(name: FIELD, uri: "https://another.example.org")
    assert_raises(DurableAssistants::Caldav::Error) { @client.item("work", "example") }
    assert_not_requested @get
  end

  test "guest-free create, update and delete send the distinct preconditions to the pinned item only" do
    get_tag, stored = @client.item("work", "example")
    assert_equal TAG, get_tag
    assert_equal "Ordinary event", stored.events.sole.summary.to_s
    create = stub_request(:put, "#{WORK}new.ics").with(headers: { "If-None-Match" => "*" }).to_return(status: 201)
    update = stub_request(:put, "#{WORK}example.ics").with(headers: { "If-Match" => TAG }).to_return(status: 204)
    delete = stub_request(:delete, "#{WORK}example.ics").with(headers: { "If-Match" => TAG }).to_return(status: 204)
    @client.put("work", "new", event)
    @client.put("work", "example", event, etag: get_tag)
    @client.delete("work", "example", get_tag)
    assert_requested create, times: 1
    assert_requested update, times: 1
    assert_requested delete, times: 1
  end

  test "stale, weak, repeated, wildcard and missing validators refuse writes" do
    [ '"old"', 'W/"etag-one"', "*", nil, '"etag-one", "other"' ].each do |bad|
      assert_equal 412, assert_raises(DurableAssistants::Caldav::Error) { @client.delete("work", "example", bad) }.status
    end
    stub_request(:get, "#{WORK}example.ics").to_return(status: 200, headers: { "ETag" => [ TAG, TAG ] }, body: event.to_ical)
    untrusted, = @client.item("work", "example")
    assert_equal "", untrusted
    assert_equal 412, assert_raises(DurableAssistants::Caldav::Error) { @client.put("work", "example", event, etag: untrusted) }.status
    assert_not_requested :put, "#{WORK}example.ics"
    assert_not_requested :delete, "#{WORK}example.ics"
  end

  test "report accepts only canonical in-collection hrefs and successful DAV properties" do
    good = event.to_ical
    entries = [ item("#{WORK}one.ics", TAG, good), item("/calendars/work/two.ics", TAG, good),
      item("https://wrong.example/calendars/work/foreign.ics", TAG, good), item("/calendars/work/%65ncoded.ics", TAG, good),
      item("/calendars/work/sub/folder.ics", TAG, good), item("/calendars/work/query.ics?q=1", TAG, good),
      item("/calendars/work/bad-status.ics", TAG, good).sub("200 OK", "404 Not Found") ]
    report = stub_request(:report, WORK).with(headers: { "Depth" => "1" }).to_return(multistatus(entries))
    assert_equal %w[ one two ], @client.items("work", "events").map(&:first)
    assert_requested report, times: 1
    assert_not_requested @get
  end

  test "the owner can save pins; malformed pins are refused and a workspace member cannot change them" do
    workspace = Workspace.create!(name: "Group")
    workspace.memberships.create!(user: @owner, role: "owner")
    @agent = @owner.start_agent("Assistant", workspace:)
    @agent.create_calendar_server!(vault_entry: FIELD, collection_urls: "#{WORK}\n#{SERVER}/team/second/\n")
    sign_in_via_ajent(subject: "sub-owner", email: @owner.email, name: @owner.name)
    endpoint = agent_calendar_server_path(@agent)
    patch endpoint, params: { calendar_server: { vault_entry: FIELD, collection_urls: "#{SERVER}/calendars/%2e/" } }
    assert_response :unprocessable_entity
    assert_equal [ WORK, "#{SERVER}/team/second/" ], @agent.calendar_server.reload.pinned_collections
    patch endpoint, params: { calendar_server: { vault_entry: FIELD, collection_urls: "#{WORK}\n#{SERVER}/new/" } }
    assert_redirected_to agent_channels_path(@agent)
    assert_equal [ WORK, "#{SERVER}/new/" ], @agent.calendar_server.reload.pinned_collections
    member = create_user(name: "Member")
    workspace.memberships.create!(user: member, role: "member")
    sign_in_via_ajent(subject: "sub-member", email: member.email, name: member.name)
    patch endpoint, params: { calendar_server: { vault_entry: FIELD, collection_urls: "#{SERVER}/not-allowed/" } }
    assert_response :not_found
    assert_equal [ WORK, "#{SERVER}/new/" ], @agent.calendar_server.reload.pinned_collections
  end

  private
    def event
      Icalendar::Calendar.new.tap do |calendar|
        calendar.event do |entry|
          entry.uid = "example"
          entry.summary = "Ordinary event"
          entry.dtstart = Icalendar::Values::DateTime.new("20261120T230000Z")
        end
      end
    end
end
