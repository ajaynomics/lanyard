require "test_helper"
require_relative "../test_helpers/bluebubbles_test_helper"

class BluebubblesTest < ActiveSupport::TestCase
  include BluebubblesTestHelper

  setup { install_bluebubbles_settings }
  teardown { remove_bluebubbles_settings }

  test "chats come named from the Mac's contacts, and a query finds them by name, number or address" do
    stub_bluebubbles
    chats = DurableAssistants::Bluebubbles.chats
    assert_equal [ MAYA, FAMILY ], chats.map { it[:guid] }
    assert_equal({ guid: MAYA, name: "Maya Patel", group: false, participants: [ "Maya Patel <+14165550199>" ], last_at: "2025-11-09T14:53:20Z" }, chats.first)
    assert_equal [ "Maya Patel <+14165550199>", "Robin Lee <robin@example.com>" ], chats.last[:participants]

    assert_equal [ MAYA, FAMILY ], DurableAssistants::Bluebubbles.chats("maya").map { it[:guid] }
    assert_equal [ FAMILY ], DurableAssistants::Bluebubbles.chats("ROBIN@").map { it[:guid] }
    assert_equal [ FAMILY ], DurableAssistants::Bluebubbles.chats("family").map { it[:guid] }
    assert_equal [ MAYA, FAMILY ], DurableAssistants::Bluebubbles.chats("416-555-0199").map { it[:guid] }
    assert_empty DurableAssistants::Bluebubbles.chats("Sam")
  end

  test "a chat's name is kept for the person approving a send; one never listed is named by its GUID" do
    stub_bluebubbles
    assert_equal({ name: "a group chat not looked up (iMessage;+;chat999)", participants: [] }, DurableAssistants::Bluebubbles.label("iMessage;+;chat999"))
    assert_equal "+14165550199", DurableAssistants::Bluebubbles.label(MAYA)[:name]
    DurableAssistants::Bluebubbles.chats
    assert_equal({ name: "Family", participants: [ "Maya Patel <+14165550199>", "Robin Lee <robin@example.com>" ] }, DurableAssistants::Bluebubbles.label(FAMILY))
  end

  test "messages leave out reactions and system lines, and say who sent each" do
    stub_bluebubbles(messages: [
      bluebubbles_message("Lunch?", guid: "m2"),
      { guid: "r1", text: "Loved \"Lunch?\"", associatedMessageType: "love", isFromMe: true },
      { guid: "s1", text: "", isSystemMessage: true },
      bluebubbles_message("Sure", from_me: true, guid: "m1") ])
    page = DurableAssistants::Bluebubbles.messages(MAYA, limit: 30)
    assert_equal [ "m2", "m1" ], page[:messages].map { it[:guid] }
    assert_equal "Maya Patel <+14165550199>", page[:messages].first[:from]
    assert page[:messages].last[:from_me]
    assert_requested(:post, "#{BLUEBUBBLES}/api/v1/message/query", query: { password: "synthetic-mac-password" }) do
      JSON.parse(it.body).slice("chatGuid", "limit", "offset", "sort") == { "chatGuid" => MAYA, "limit" => 30, "offset" => 0, "sort" => "DESC" }
    end
  end

  test "a send is the message's GUID; refused before it went is an error, and anything uncertain is unknown" do
    sends = stub_bluebubbles
    assert_equal({ guid: "sent-1", delivered: true }, DurableAssistants::Bluebubbles.send_text(MAYA, "On my way."))
    assert_equal({ "chatGuid" => MAYA, "message" => "On my way.", "method" => "apple-script" }, sends.sole.except("tempGuid"))

    stub_bluebubbles(send: { status: 400, body: { message: "bad chat" }.to_json })
    assert_raises(DurableAssistants::Bluebubbles::Error) { DurableAssistants::Bluebubbles.send_text(MAYA, "Hi") }
    [ { status: 500, body: "{}" }, ->(_) { raise Net::ReadTimeout }, { guid: nil } ].each do |answer|
      stub_bluebubbles(send: answer)
      error = assert_raises(DurableAssistants::Bluebubbles::Unknown) { DurableAssistants::Bluebubbles.send_text(MAYA, "Hi") }
      assert_no_match(/password|synthetic|mac\.example/, error.message)
    end
  end

  # The password opens every message on the Mac, and BlueBubbles takes it only
  # in a URL: so nothing but this file holds it, it asks for four things, and
  # no error it raises repeats the URL.
  test "it asks BlueBubbles for chats, messages, contacts and one send, and is the only code that can ask" do
    assert_equal %w[ /api/v1/chat/query /api/v1/message/query /api/v1/contact /api/v1/message/text ], DurableAssistants::Bluebubbles::PATHS
    %w[ /api/v1/chat/iMessage;-;+1/leave /api/v1/server/restart /api/v1/message/attachment ].each do |path|
      assert_raises(ArgumentError) { DurableAssistants::Bluebubbles.send(:request, path) }
    end
    assert_raises(ArgumentError) { DurableAssistants::Bluebubbles.send(:request, DurableAssistants::Bluebubbles::SEND, {}) }
    assert_raises(NoMethodError) { DurableAssistants::Bluebubbles.request(DurableAssistants::Bluebubbles::CHATS) }

    stub_request(:any, /mac\.example\.com/).to_timeout
    error = assert_raises(DurableAssistants::Bluebubbles::Error) { DurableAssistants::Bluebubbles.chats }
    assert_equal "BlueBubbles didn't answer (OpenTimeout)", error.message

    callers = Dir[Rails.root.join("{app,lib,config,agent}/**/*.{rb,mjs,js,yml,erb}")].reject { it.include?("node_modules") }
      .select { File.read(it).match?(/:bluebubbles, :password|setting\(:password\)/) }
    assert_equal [ "config/bluebubbles.yml", "lib/durable_assistants/bluebubbles.rb", "lib/durable_assistants/voipms.rb" ], callers.map { it.delete_prefix("#{Rails.root}/") }.sort
  end
end
