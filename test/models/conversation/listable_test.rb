require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversation::ListableTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user.agents.sole
  end

  test "search matches a title or a person's or the agent's words, but not a tool's output" do
    titled = conversation("Trip to Lisbon")
    asked = conversation("Untitled").tap { it.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Where is LISBON?") }
    replied = conversation("Other").tap { it.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "lisbon is warm") }
    conversation("Tool").messages.create!(entry_key: "1", entry_id: 1, role: "toolResult", content: "lisbon.txt")

    assert_equal [ titled, asked, replied ].sort_by(&:id), @agent.conversations.search("lisbon").order(:id).to_a
    assert_equal @agent.conversations.count, @agent.conversations.search(" ").count
    assert_equal @agent.conversations.count, @agent.conversations.search(nil).count
  end

  test "search takes % and _ literally" do
    percent = conversation("100% done")
    conversation("100 done")
    underscore = conversation("my_file")
    conversation("myXfile")

    assert_equal [ percent ], @agent.conversations.search("0%").to_a
    assert_equal [ underscore ], @agent.conversations.search("y_f").to_a
  end

  test "search never finds another person's conversation" do
    mine = conversation("Secret plan")
    theirs = create_user(name: "Mallory").agents.sole
    theirs.conversations.create!(user: theirs.user, request_id: "m", durable_id: "m", title: "Secret plan")

    assert_equal [ mine ], @agent.conversations.search("secret").to_a
  end

  test "sorted_by: recent message first, newest first, title ignoring case; an unknown key is recent" do
    old = conversation("banana", created_at: 3.days.ago, last_message_at: 1.minute.ago)
    mid = conversation("Apple", created_at: 2.days.ago, last_message_at: 2.days.ago)
    new = conversation("cherry", created_at: 1.day.ago, last_message_at: 1.day.ago)

    assert_equal [ old, new, mid ], @agent.conversations.sorted_by("recent").to_a
    assert_equal [ new, mid, old ], @agent.conversations.sorted_by("created").to_a
    assert_equal [ mid, old, new ], @agent.conversations.sorted_by("title").to_a
    assert_equal [ old, new, mid ], @agent.conversations.sorted_by("id; DROP TABLE conversations").to_a
    assert_equal [ old, new, mid ], @agent.conversations.sorted_by(nil).to_a
  end

  test "filtered_by: active, waiting, branched, archived and all; an unknown key is active" do
    active = conversation("Active")
    waiting = conversation("Waiting", status: "waiting")
    archived_waiting = conversation("Old question", status: "waiting", archived_at: 1.day.ago)
    branched = conversation("Branched", branches_count: 2)

    assert_equal [ active, waiting, branched ], @agent.conversations.filtered_by("active").order(:id).to_a
    assert_equal [ waiting ], @agent.conversations.filtered_by("waiting").to_a
    assert_equal [ branched ], @agent.conversations.filtered_by("branched").to_a
    assert_equal [ archived_waiting ], @agent.conversations.filtered_by("archived").to_a
    assert_equal 4, @agent.conversations.filtered_by("all").count
    assert_equal [ active, waiting, branched ], @agent.conversations.filtered_by("deleted").order(:id).to_a
    assert_equal [ active, waiting, branched ], @agent.conversations.filtered_by(nil).order(:id).to_a
  end

  test "archive stamps the conversation and unarchive clears it" do
    talk = conversation("Talk")

    talk.archive
    assert talk.reload.archived?

    talk.unarchive
    assert_nil talk.reload.archived_at
    assert_not talk.archived?
  end

  test "a new message moves the conversation's last message time; a status change does not" do
    talk = travel_to(2.days.ago) { conversation("Talk") }
    assert_in_delta 2.days.ago, talk.last_message_at, 1.minute

    talk.update!(status: "running")
    assert_in_delta 2.days.ago, talk.reload.last_message_at, 1.minute

    talk.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Hi")
    assert_in_delta Time.current, talk.reload.last_message_at, 1.minute
  end

  test "a strict list refuses to reach an association from a row" do
    conversation("Talk")

    assert_raises(ActiveRecord::StrictLoadingViolationError) do
      @agent.conversations.filtered_by(nil).search(nil).sorted_by(nil).strict_loading.first.messages.to_a
    end
  end

  private
    def conversation(title, **attributes)
      @count = @count.to_i + 1
      @agent.conversations.create!(user: @agent.user, request_id: "r-#{@count}", durable_id: "d-#{@count}", title: title, **attributes)
    end
end
