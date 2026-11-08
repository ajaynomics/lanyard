require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Conversation::ListableTest < ActiveSupport::TestCase
  include AgentTestHelper

  # Each row is an agent's thread, so each test gets agents of its own, not the starter.
  setup do
    @user = create_user
    @user.agents.destroy_all
  end

  test "search matches an agent's name or a person's or the agent's words, but not a tool's output" do
    named = thread("Trip to Lisbon")
    asked = thread("Untitled").tap { it.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Where is LISBON?") }
    replied = thread("Other").tap { it.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "lisbon is warm") }
    thread("Tool").messages.create!(entry_key: "1", entry_id: 1, role: "toolResult", content: "lisbon.txt")

    assert_equal [ named, asked, replied ].sort_by(&:id), threads.search("lisbon").order(:id).to_a
    assert_equal threads.count, threads.search(" ").count
    assert_equal threads.count, threads.search(nil).count
  end

  test "search takes % and _ literally" do
    percent = thread("100% done")
    thread("100 done")
    underscore = thread("my_file")
    thread("myXfile")

    assert_equal [ percent ], threads.search("0%").to_a
    assert_equal [ underscore ], threads.search("y_f").to_a
  end

  test "search never finds another person's agent" do
    mine = thread("Secret plan")
    name_agent(create_user(name: "Mallory").agents.sole, "Secret plan")

    assert_equal [ mine ], threads.search("secret").to_a
  end

  test "threads leave out branches" do
    talk = thread("Talk")
    @user.conversations.create!(agent: talk.agent, parent: talk, root: talk, request_id: "b", durable_id: "b", title: "Branch")

    assert_equal [ talk ], threads.to_a
  end

  test "sorted_by: recent message first, newest first, name ignoring case; an unknown key is recent" do
    old = thread("banana", created_at: 3.days.ago, last_message_at: 1.minute.ago)
    mid = thread("Apple", created_at: 2.days.ago, last_message_at: 2.days.ago)
    new = thread("cherry", created_at: 1.day.ago, last_message_at: 1.day.ago)

    assert_equal [ old, new, mid ], threads.sorted_by("recent").to_a
    assert_equal [ new, mid, old ], threads.sorted_by("created").to_a
    assert_equal [ mid, old, new ], threads.sorted_by("title").to_a
    assert_equal [ old, new, mid ], threads.sorted_by("id; DROP TABLE conversations").to_a
    assert_equal [ old, new, mid ], threads.sorted_by(nil).to_a
  end

  test "filtered_by: active, waiting, archived and all; an unknown key, branched among them, is active" do
    active = thread("Active")
    waiting = thread("Waiting", status: "waiting")
    archived_waiting = thread("Old question", status: "waiting", archived_at: 1.day.ago)
    branched = thread("Branched", branches_count: 2)

    assert_equal [ active, waiting, branched ], threads.filtered_by("active").order(:id).to_a
    assert_equal [ waiting ], threads.filtered_by("waiting").to_a
    assert_equal [ active, waiting, branched ], threads.filtered_by("branched").order(:id).to_a
    assert_equal [ archived_waiting ], threads.filtered_by("archived").to_a
    assert_equal 4, threads.filtered_by("all").count
    assert_equal [ active, waiting, branched ], threads.filtered_by("deleted").order(:id).to_a
    assert_equal [ active, waiting, branched ], threads.filtered_by(nil).order(:id).to_a
  end

  test "archive stamps the conversation and unarchive clears it" do
    talk = thread("Talk")

    talk.archive
    assert talk.reload.archived?

    talk.unarchive
    assert_nil talk.reload.archived_at
    assert_not talk.archived?
  end

  test "a new message moves the conversation's last message time; a status change does not" do
    talk = travel_to(2.days.ago) { thread("Talk") }
    assert_in_delta 2.days.ago, talk.last_message_at, 1.minute

    talk.update!(status: "running")
    assert_in_delta 2.days.ago, talk.reload.last_message_at, 1.minute

    talk.messages.create!(entry_key: "1", entry_id: 1, role: "user", content: "Hi")
    assert_in_delta Time.current, talk.reload.last_message_at, 1.minute
  end

  test "a strict list refuses to reach an association from a row" do
    thread("Talk")

    assert_raises(ActiveRecord::StrictLoadingViolationError) do
      threads.filtered_by(nil).search(nil).sorted_by(nil).strict_loading.first.messages.to_a
    end
  end

  private
    def threads = @user.conversations.threads

    # An agent named `name`, made like the starter, and its thread.
    def thread(name, **attributes)
      @user.start_agent(name).conversation.tap { it.update_columns(attributes) if attributes.any? }
    end
end
