require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A bot with full read and write in a group (#249, docs/telegram.md).
# Privacy mode is off, so Telegram posts every message in the group: every
# one is stored, and only a mention of the bot or a reply to it starts a
# turn. telegram_messages reads what was stored, the bot's own posts among
# them, which come from the send ledger because Telegram never echoes a bot
# its own messages. A send that may or may not have gone says so, is never
# made again on its own, and is marked sent once a later post reveals its id.
class TelegramMessagesTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  TOKEN = "123456789:AAFakeTokenForTests_only-0123456789abcd".freeze
  API = "https://api.telegram.org/bot#{TOKEN}".freeze
  GROUP = -1001234567890
  DEPOT = -1009876501234
  SECRET = "X-Telegram-Bot-Api-Secret-Token".freeze

  setup do
    install_sidecar_settings
    install_fake_passbolt(name: "Rowan bot", uri: "https://api.telegram.org", password: TOKEN)
    @alice = create_user(name: "Alice")
    @agent = name_agent(@alice.agents.sole, "Rowan")
    @conversation = create_conversation(@agent)
    @bot = @agent.create_telegram_bot!(vault_entry: "Rowan bot", username: "rowan_example_bot")
    @submissions = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/12/submissions").to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: 1, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/12/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/12/wake}).to_return(status: 202, body: "{}")
  end

  teardown do
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "every post in the group is stored, and only one that names or answers the bot wakes the agent" do
    deliver 1101, text: "Trucks at eight."
    deliver 1102, text: "I'll open the gate."
    deliver 1103, **mentioning("can you tell the site?")
    perform_enqueued_jobs only: TelegramReceiveJob

    assert_equal [ 1101, 1102, 1103 ], @bot.messages.order(:message_id).map(&:message_id),
      "privacy mode is off, so every post arrives and every one is kept"
    assert_equal 1, @submissions.size, "only the one that names the bot starts a turn"
    assert_match "can you tell the site?", words(@submissions.sole["content"])
  end

  # Catching up on a group is one call with no words: the chat alone gives
  # its latest posts, the bot's own sends in their place among them.
  test "a chat and no words give its latest posts, the bot's own sends among them" do
    sent = stub_send(GROUP, "On my way.")
    travel_to(Time.utc(2026, 11, 19, 9, 0)) { deliver 1201, text: "Trucks at eight." }
    travel_to(Time.utc(2026, 11, 19, 9, 5)) { say "On my way.", call_id: "s1" }
    travel_to(Time.utc(2026, 11, 19, 9, 10)) { deliver 1202, text: "Gate's open." }
    perform_enqueued_jobs only: TelegramReceiveJob
    assert_requested sent, times: 1

    said = read(chat: GROUP.to_s, call_id: "h1")["messages"]

    assert_equal [ "Gate's open.", "On my way.", "Trucks at eight." ], said.pluck("text"), "newest first"
    assert_equal [ "Maya Reyes", "Rowan", "Maya Reyes" ], said.pluck("from")
    assert_equal [ nil, true, nil ], said.pluck("yours"), "its own posts are marked as its own"
    assert_equal [ 1202, 77, 1201 ], said.pluck("id"), "each with Telegram's id for it"
    assert_equal [ { "id" => GROUP, "name" => "Site notes" } ], said.pluck("chat").uniq
    assert_equal Time.utc(2026, 11, 19, 9, 5).in_time_zone(@agent.time_zone).iso8601, said.second["at"],
      "each time in the agent's own zone, as every other channel's is"
  end

  # The one read tool answers "did mine arrive?" as well as "what was said?",
  # so a send still waiting is in the list, marked unknown and without an id.
  test "a send whose answer never came is listed as its own, and marked unknown" do
    stub_request(:post, "#{API}/sendMessage").to_raise(Errno::ECONNRESET)
    say "Trucks at eight?", call_id: "s9"
    deliver 1210, text: "Morning."
    perform_enqueued_jobs only: TelegramReceiveJob

    mine = read(chat: GROUP.to_s, call_id: "h9")["messages"].find { it["yours"] }

    assert_equal "Trucks at eight?", mine["text"]
    assert mine["unknown"], "whether it went is not known, so the agent is told here too"
    assert_nil mine["id"], "Telegram never answered, so there is no id for it"
  end

  test "words and a chat narrow the bot's own sends as they narrow what it heard" do
    stub_send(GROUP, "Trucks are here.")
    deliver 1301, text: "Are the trucks there?"
    deliver 1302, text: "Gate's open."
    deliver 1303, chat: depot, text: "Trucks are loading."
    perform_enqueued_jobs only: TelegramReceiveJob
    say "Trucks are here.", call_id: "s10"

    found = read(query: "trucks", call_id: "h10")["messages"]
    assert_includes found.pluck("text"), "Trucks are here.", "the words match a send of its own too"
    assert_not_includes found.pluck("text"), "Gate's open."

    in_group = read(chat: "Site notes", query: "trucks", call_id: "h11")["messages"]
    assert_equal [ "Trucks are here.", "Are the trucks there?" ], in_group.pluck("text"),
      "a chat's title names it, for its sends as for its posts"

    in_depot = read(chat: "Depot", query: "trucks", call_id: "h12")["messages"]
    assert_equal [ "Trucks are loading." ], in_depot.pluck("text"), "a chat the send didn't go to leaves it out"
  end

  test "another agent's bot's posts and sends never show, even in the same group" do
    felix = name_agent(create_user(name: "Bob").agents.sole, "Felix")
    other_bot = felix.create_telegram_bot!(vault_entry: "Felix bot", username: "felix_example_bot")
    post telegram_webhook_path(other_bot), params: update(1401, chat: group, text: "Felix heard this."),
      as: :json, headers: { SECRET => other_bot.webhook_secret }
    deliver 1402, text: "Ours."
    perform_enqueued_jobs only: TelegramReceiveJob
    felix_sent(felix, "Felix sent this.")

    said = read(chat: GROUP.to_s, call_id: "h13")["messages"]

    assert_equal [ "Ours." ], said.pluck("text"), "its own bot's record and its own ledger, and no one else's"
    assert_not_includes said.to_json, "Felix"
  end

  test "telegram_messages reads only the chats this agent's bot is in" do
    other = create_user(name: "Bob")
    other_bot = name_agent(other.agents.sole, "Felix").create_telegram_bot!(vault_entry: "Felix bot", username: "felix_example_bot")
    post telegram_webhook_path(other_bot), params: update(1301, chat: { id: -1009876543210, type: "supergroup", title: "Felix's group" },
      text: "Ours alone."), as: :json, headers: { SECRET => other_bot.webhook_secret }
    perform_enqueued_jobs only: TelegramReceiveJob
    assert_equal [ "Ours alone." ], other_bot.messages.pluck(:text)

    outcome = receive("telegram_messages", { "chat" => "-1009876543210" }, call_id: "h2")
    perform_enqueued_jobs only: InvocationCallJob
    invocation = @conversation.invocations.find_by!(call_id: "h2")

    assert invocation.failed?
    assert_match(/-1009876543210/, invocation.error)
    assert_not_includes outcome.to_s + invocation.error.to_s, "Ours alone."
  end

  test "a send whose connection is reset is unknown, never failed, and never sent again on its own" do
    sent = stub_request(:post, "#{API}/sendMessage").to_raise(Errno::ECONNRESET)
    say "Trucks at eight?", call_id: "s2"

    invocation = @conversation.invocations.find_by!(call_id: "s2")
    assert invocation.succeeded?, "a send that may have gone is not a failure: #{invocation.error}"
    assert_equal GROUP, invocation.result["unknown"]
    assert_match(/telegram_messages/, invocation.result["note"])
    assert_match(/don't send it again/i, invocation.result["note"])
    assert_equal "unknown", invocation.dispatch.state
    assert_nil invocation.dispatch.provider_id

    say "Trucks at eight?", call_id: "s3"
    assert_requested sent, times: 1 # the same words again send nothing
    assert_match(/unknown/i, @conversation.invocations.find_by!(call_id: "s3").error)
  end

  test "a send Telegram refuses with a 400 is a failure, and nothing is recorded as sent" do
    stub_request(:post, "#{API}/sendMessage")
      .to_return(status: 400, body: { ok: false, error_code: 400, description: "Bad Request: chat not found" }.to_json)
    say "Trucks at eight?", call_id: "s4"

    invocation = @conversation.invocations.find_by!(call_id: "s4")
    assert invocation.failed?
    assert_match "chat not found", invocation.error
    assert_match "nothing was sent", invocation.error
    assert_equal "not_sent", invocation.dispatch.state
  end

  test "a later reply quoting the bot's post reveals its id and marks the send as sent" do
    stub_request(:post, "#{API}/sendMessage").to_raise(Errno::ECONNRESET)
    say "Trucks at eight?", call_id: "s5"
    dispatch = @conversation.invocations.find_by!(call_id: "s5").dispatch
    assert dispatch.unknown?

    deliver 1403, text: "Yes, eight.", reply_to_message: { message_id: 904, date: Time.utc(2026, 11, 19, 9).to_i, chat: group,
      from: { id: 123456789, is_bot: true, first_name: "Rowan", username: "rowan_example_bot" }, text: "Trucks at eight?" }
    perform_enqueued_jobs only: TelegramReceiveJob

    assert dispatch.reload.sent?, "the reply carries the post it answers, whole, with Telegram's id for it"
    assert_equal "904", dispatch.provider_id
    assert_equal 904, read(chat: GROUP.to_s, call_id: "h3")["messages"].find { it["yours"] }["id"]
  end

  # Telegram lists nothing a bot sent, so a send left waiting by a crash
  # can never be found: it is unknown at its first check, not after a day of
  # asks that cannot be answered, and the agent is told once.
  test "a Telegram send left waiting by a crash is unknown at its first check, and told once" do
    dispatch = crashed_send("Trucks at eight?", call_id: "c1")

    assert_no_enqueued_jobs(only: DispatchCheckJob) { dispatch.check }
    assert dispatch.reload.unknown?
    assert_equal 1, dispatch.checks
    perform_enqueued_jobs only: DispatchReportJob
    assert_equal [ "dispatch:#{dispatch.id}" ], @submissions.map { it["requestId"] }
  end

  # A check reported it unknown under the dispatch's own request id; that it
  # went after all is a second message, so it needs its own id, or the
  # thread would drop it as a repeat of the first.
  test "an unknown send a reply later reveals is reported again, under its own request id" do
    dispatch = crashed_send("Trucks at eight?", call_id: "c2")
    dispatch.check
    perform_enqueued_jobs only: DispatchReportJob

    deliver 1404, text: "Yes, eight.", reply_to_message: { message_id: 905, date: Time.utc(2026, 11, 19, 9).to_i, chat: group,
      from: { id: 123456789, is_bot: true, first_name: "Rowan", username: "rowan_example_bot" }, text: "Trucks at eight?" }
    perform_enqueued_jobs only: TelegramReceiveJob
    perform_enqueued_jobs only: DispatchReportJob

    assert dispatch.reload.sent?
    told = @submissions.select { it["requestId"].to_s.start_with?("dispatch:") }
    assert_equal [ "dispatch:#{dispatch.id}", "dispatch:#{dispatch.id}:revealed" ], told.map { it["requestId"] }
    assert_match(/went after all/, told.last.to_json)
  end

  # "Not sent" invites a second send, so only a person says it: nothing a
  # bot or a check does moves a send there, and a person's answer stands.
  test "nothing automatic moves a send to not sent, and a person's answer is never overwritten" do
    dispatch = crashed_send("Trucks at eight?", call_id: "c3")
    dispatch.check
    dispatch.check
    assert dispatch.reload.unknown?

    assert dispatch.close(went: false, by: @alice)
    dispatch.send(:revealed, 906)
    assert dispatch.reload.not_sent?, "a person said it didn't go; a later reply doesn't overrule that here"
    assert_nil dispatch.provider_id

    other = crashed_send("Cones at nine?", call_id: "c4")
    other.check
    assert other.close(went: true, by: @alice)
    other.send(:revealed, 907)
    assert_equal "sent", other.reload.state
    assert_nil other.provider_id
  end

  test "the Telegram channel row says every group post that reaches the bot is stored, what wakes the agent, and privacy mode's limit" do
    row = Agent::Received.new(@agent.reload, since: 1.hour.ago).to_h[:channels].find { it[:channel] == "Telegram" }

    assert_equal "Telegram: none", "Telegram: #{row[:status]}"
    assert_match(/every one that reaches the bot is stored/i, row[:unseen])
    assert_match(/telegram_messages/, row[:unseen])
    assert_match(/only a mention or a reply/i, row[:unseen])
    assert_match(/With privacy mode on, Telegram sends the bot only mentions and replies/, row[:unseen], "true of any bot whose group has it on")
  end

  private
    def group = { id: GROUP, type: "supergroup", title: "Site notes" }

    def depot = { id: DEPOT, type: "supergroup", title: "Depot" }

    def mentioning(words) = { text: "@rowan_example_bot #{words}", entities: [ { type: "mention", offset: 0, length: 18 } ] }

    def update(id, chat:, from: { id: 42, is_bot: false, first_name: "Maya", last_name: "Reyes", username: "maya_r" }, **message)
      { update_id: id, message: { message_id: id, date: Time.current.to_i, chat: chat, from: from, **message } }
    end

    def deliver(id, chat: group, **message)
      post telegram_webhook_path(@bot), params: update(id, chat: chat, **message), as: :json, headers: { SECRET => @bot.webhook_secret }
      assert_response :ok
    end

    def stub_send(chat, text)
      stub_request(:post, "#{API}/sendMessage").with(body: { chat_id: chat, text: text }.to_json, headers: { "Content-Type" => "application/json" })
        .to_return(body: { ok: true, result: { message_id: 77, chat: { id: chat }, date: 1 } }.to_json)
    end

    # One send, approved by the person as every Telegram send is.
    def say(text, call_id:, chat: GROUP)
      receive("telegram_send", { "chat" => chat, "text" => text }, call_id: call_id)
      invocation = @conversation.invocations.find_by!(call_id: call_id)
      invocation.approve!(by: @alice) if invocation.awaiting_person?
      receive("telegram_send", { "chat" => chat, "text" => text }, call_id: call_id)
      perform_enqueued_jobs only: InvocationCallJob
    end

    # Another agent's send of its own, in the ledger as its call left it.
    def felix_sent(agent, text, chat: GROUP)
      invocation = agent.conversation.invocations.create!(task_id: "9", call_id: "f1", tool_name: "telegram_send",
        arguments: { "chat" => chat, "text" => text }, digest: "d", state: "succeeded")
      Dispatch.record(invocation, tool_name: "telegram_send", sender: "@felix_example_bot",
        fingerprint: Dispatch.fingerprint("telegram_send", "@felix_example_bot", chat, text)).confirm(555)
    end

    # A send whose call crashed before it settled: still waiting, as a
    # restart would leave it.
    def crashed_send(text, call_id:)
      stub_request(:post, "#{API}/sendMessage").to_raise(Errno::ECONNRESET)
      say text, call_id: call_id
      @conversation.invocations.find_by!(call_id: call_id).dispatch.tap do
        it.update_columns(state: "pending", settled_at: nil, created_at: 10.minutes.ago)
        it.invocation.update_columns(updated_at: 10.minutes.ago)
      end
    end

    def read(call_id:, **arguments)
      receive("telegram_messages", arguments.transform_keys(&:to_s), call_id: call_id)
      perform_enqueued_jobs only: InvocationCallJob
      @conversation.invocations.find_by!(call_id: call_id).then { it.result || raise(it.error.to_s) }
    end

    def receive(tool, arguments, call_id:, conversation: @conversation)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation.reload, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
