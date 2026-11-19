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
      assert_equal collection, @agent.linked_calendar_collection.to_s
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
    assert_nil @agent.linked_calendar_collection
  end
end
