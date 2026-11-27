require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agent::LinkedCalendarTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup { @agent = create_user(name: "Maya").agents.sole }

  test "the calendar is its full address, or its id or path under the server's" do
    { [ "https://caldav.example.com/123/calendars", "family" ] => "https://caldav.example.com/123/calendars/family/",
      [ "https://caldav.example.com", "/123/calendars/family" ] => "https://caldav.example.com/123/calendars/family/",
      [ "https://caldav.example.com/", "https://caldav.example.com/123/calendars/family/" ] => "https://caldav.example.com/123/calendars/family/" }.each do |(server, calendar), collection|
      @agent.assign_attributes(linked_calendar_server: " #{server} ", linked_calendar: calendar, linked_calendar_entry: "Family")
      assert @agent.valid?, @agent.errors.full_messages.to_sentence
      assert_equal [ collection ], @agent.linked_calendar_collections.map(&:to_s)
    end
  end

  test "it names one calendar, over https, on the server named" do
    { [ "http://caldav.example.com", "family" ] => "https", [ "https://caldav.example.com", "https://elsewhere.example/family/" ] => "server named",
      [ "https://caldav.example.com", "/" ] => "one calendar", [ "https://caldav.example.com", "family?x=1" ] => "plain address",
      [ "https://caldav.example.com", nil ] => "both" }.each do |(server, calendar), problem|
      @agent.assign_attributes(linked_calendar_server: server, linked_calendar: calendar)
      assert_not @agent.valid?, [ server, calendar ].inspect
      assert_match problem, @agent.errors[:linked_calendar].to_sentence
    end
  end

  test "a . or .. is refused as typed, though joining would resolve it to a calendar" do
    { [ "https://caldav.example.com", "/123/calendars/family/../../" ] => :linked_calendar, [ "https://caldav.example.com", "/123/./family" ] => :linked_calendar,
      [ "https://caldav.example.com", "/123/%2e%2E/family" ] => :linked_calendar, [ "https://caldav.example.com/123/x/..", "family" ] => :linked_calendar_server }.each do |(server, calendar), attribute|
      @agent.assign_attributes(linked_calendar_server: server, linked_calendar: calendar, linked_calendar_entry: "Family")
      assert_not @agent.valid?, [ server, calendar ].inspect
      assert_match "must not have . or ..", @agent.errors[attribute].to_sentence
    end
  end

  test "none set is none linked" do
    assert @agent.valid?
    assert_not @agent.linked_calendar?
    assert_empty @agent.linked_calendar_collections
  end

  test "several calendars of the same account, one a line, each its own list" do
    @agent.assign_attributes(linked_calendar_server: "https://caldav.example.com", linked_calendar_entry: "Family",
      linked_calendar: " /123/calendars/family/ \r\n\r\nhttps://caldav.example.com/123/calendars/class/\n")
    assert @agent.valid?, @agent.errors.full_messages.to_sentence
    assert_equal "/123/calendars/family/\nhttps://caldav.example.com/123/calendars/class/", @agent.linked_calendar
    assert_equal %w[ https://caldav.example.com/123/calendars/family/ https://caldav.example.com/123/calendars/class/ ], @agent.linked_calendar_collections.map(&:to_s)
  end

  test "each line is checked, and two may not share a name" do
    { "family\nhttps://elsewhere.example/class/" => "server named", "family\n/123/../class" => "must not have . or ..",
      "/123/family/\n/456/family/" => "different names", (1..21).map { "c#{it}" }.join("\n") => "at most 20" }.each do |calendars, problem|
      @agent.assign_attributes(linked_calendar_server: "https://caldav.example.com", linked_calendar: calendars, linked_calendar_entry: "Family")
      assert_not @agent.valid?, calendars.inspect
      assert_match problem, @agent.errors[:linked_calendar].to_sentence
    end
  end

  test "an agent linked to one calendar before keeps it as it was" do
    @agent.update_columns(linked_calendar_server: "https://caldav.example.com", linked_calendar: "/123/calendars/family/", linked_calendar_entry: "Family")
    @agent.reload
    assert @agent.valid?
    assert_equal "/123/calendars/family/", @agent.linked_calendar
    assert_equal [ "https://caldav.example.com/123/calendars/family/" ], @agent.linked_calendar_collections.map(&:to_s)
  end
end
