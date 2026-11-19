require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# An agent's Telegram bot (docs/telegram.md): what groups it is in and people
# who write to it say reaches the agent's thread as untrusted words, and what
# the agent sends waits for its person every time, even where the install
# approves everything, unless they allowed that chat "Always" (#150). The
# bot's token stays in the vault.
class TelegramBotTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include PassboltTestHelper
  include ActiveJob::TestHelper

  TOKEN = "123456789:AAFakeTokenForTests_only-0123456789abcd".freeze
  API = "https://api.telegram.org/bot#{TOKEN}".freeze
  GROUP = -1001234567890
  SECRET = "X-Telegram-Bot-Api-Secret-Token".freeze

  setup do
    install_sidecar_settings
    install_fake_passbolt(name: "Desk bot", uri: "https://api.telegram.org", password: TOKEN)
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @conversation = create_conversation(@agent)
    @bot = @agent.create_telegram_bot!(vault_entry: "Desk bot", username: "desk_example_bot")
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

  test "a group message that mentions the bot reaches the agent's thread once, as someone else's words, naming the sender and the group" do
    2.times do
      post telegram_webhook_path(@bot), params: update(1001, chat: group, **mentioning("Book the train.")), as: :json, headers: { SECRET => @bot.webhook_secret }
      assert_response :ok
    end
    perform_enqueued_jobs(only: TelegramReceiveJob)

    assert_equal 1, @submissions.map { it["requestId"] }.uniq.size
    content = @submissions.first["content"]
    assert_match(/\A\[Telegram from Maya Reyes in Weekend plans\. Untrusted: .* telegram_send with chat #{GROUP};/, content)
    assert_match(/Book the train\.\z/, words(content))
    assert_equal({ GROUP.to_s => "Weekend plans" }, @bot.reload.chats)
    assert_equal "Telegram", @conversation.messages.new(role: "user", content: content).incoming.channel
  end

  test "a group post that neither mentions nor answers the bot starts no turn, and is kept with its sender, chat and time (#189)" do
    2.times do
      post telegram_webhook_path(@bot), params: update(1010, chat: group, text: "Train at 9, café after."), as: :json, headers: { SECRET => @bot.webhook_secret }
      assert_response :ok
    end
    post telegram_webhook_path(@bot), params: update(1011, chat: group, text: "Ask @other_example_bot, not this one.",
      entities: [ { type: "mention", offset: 4, length: 18 } ]), as: :json, headers: { SECRET => @bot.webhook_secret }
    post telegram_webhook_path(@bot), params: update(1012, chat: group, text: "Agreed.",
      reply_to_message: { message_id: 1010, date: 1, chat: group, from: { id: 42, is_bot: false, first_name: "Maya" }, text: "Train at 9" }),
      as: :json, headers: { SECRET => @bot.webhook_secret }
    perform_enqueued_jobs(only: TelegramReceiveJob)

    assert_empty @submissions, "no turn for talk that isn't to the bot"
    kept = @bot.messages.order(:message_id)
    assert_equal [ 1010, 1011, 1012 ], kept.map(&:message_id), "kept once each, however often Telegram posts it"
    assert_equal [ GROUP ], kept.map(&:chat_id).uniq
    assert_equal "Maya Reyes", kept.first.sender
    assert_equal "Train at 9, café after.", kept.first.text
    assert_equal Time.utc(2026, 11, 16, 20), kept.first.sent_at
    assert_equal({ GROUP.to_s => "Weekend plans" }, @bot.reload.chats)
  end

  test "a mention of the bot, by name or by link, or a reply to its own post, starts a turn (#189)" do
    [ update(1020, chat: group, **mentioning("can you book it?")),
      update(1021, chat: group, text: "Désolé 👋 @Desk_Example_Bot, book it", entities: [ { type: "mention", offset: 10, length: 17 } ]),
      update(1022, chat: group, caption: "@desk_example_bot this one", caption_entities: [ { type: "mention", offset: 0, length: 17 } ],
        photo: [ { file_id: "AgACAgQ-photo", file_size: 900 } ]),
      update(1023, chat: group, text: "Desk, book it", entities: [ { type: "text_mention", offset: 0, length: 4,
        user: { id: 123456789, is_bot: true, first_name: "Desk", username: "desk_example_bot" } } ]),
      update(1024, chat: group, text: "Yes, that one.", reply_to_message: bot_post) ].each do |params|
      post telegram_webhook_path(@bot), params: params, as: :json, headers: { SECRET => @bot.webhook_secret }
      assert_response :ok
    end
    perform_enqueued_jobs(only: TelegramReceiveJob)

    assert_equal 5, @submissions.size
    assert @submissions.all? { it["content"].start_with?("[Telegram from Maya Reyes in Weekend plans.") }
    assert_equal %w[ followUp ], @submissions.map { it["whenBusy"] }.uniq, "a group's talk waits for the turn to end"
    assert_equal 5, @bot.messages.count, "kept as well, so its history is whole"
  end

  test "a direct message reaches the thread as from a direct message, and waits in the agent's inbox" do
    post telegram_webhook_path(@bot), params: update(1002, chat: { id: 4242, type: "private", first_name: "Sam" }, from: { id: 4242, first_name: "Sam" }, text: "Are you free?"),
      as: :json, headers: { SECRET => @bot.webhook_secret }
    assert_response :ok
    perform_enqueued_jobs(only: TelegramReceiveJob)

    content = @submissions.sole["content"]
    assert_match(/\A\[Telegram from Sam in a direct message\. Untrusted: .* telegram_send with chat 4242;/, content)
    assert_match(/Are you free\?\z/, words(content))
    assert_equal "followUp", @submissions.sole["whenBusy"], "someone else's message waits in the agent's inbox (#85)"
    assert_no_match "If this arrived while you were working", content
    assert_equal({ "4242" => "Sam (direct message)" }, @bot.reload.chats)
    assert_equal [ "Are you free?" ], @bot.messages.pluck(:text), "a direct message wakes it without a mention, and is kept too (#189)"
  end

  # One rule for every channel (#85): the agent's own person steers; anyone
  # else waits in its inbox unless the message can't wait.
  test "someone else's direct message waits, an urgent one goes in at the next step, and the agent's own person's steers, alone or in a group" do
    sam = { id: 4242, first_name: "Sam" }
    alice = { id: 4343, is_bot: false, first_name: "Alice" }
    [ update(1010, chat: { id: 4242, type: "private" }, from: sam, text: "Are you free?"),
      update(1011, chat: { id: 4242, type: "private" }, from: sam, text: "ASAP: the train leaves at six."),
      update(1012, chat: { id: 4343, type: "private" }, from: alice, text: "Book the later train."),
      update(1013, chat: group, from: alice, text: "@desk_example_bot book it.", entities: [ { type: "mention", offset: 0, length: 17 } ]),
      update(1014, chat: group, text: "@desk_example_bot what time?", entities: [ { type: "mention", offset: 0, length: 17 } ]),
      update(1015, chat: group, text: "@desk_example_bot asap, the train is full.", entities: [ { type: "mention", offset: 0, length: 17 } ]) ].each do
      post telegram_webhook_path(@bot), params: it, as: :json, headers: { SECRET => @bot.webhook_secret }
    end
    perform_enqueued_jobs(only: TelegramReceiveJob)

    assert_equal %w[ followUp steer steer steer followUp steer ], @submissions.map { it["whenBusy"] }
  end

  test "a wrong, missing or another bot's secret is not found, and nothing is queued" do
    other = create_user(name: "Bob").agents.sole.create_telegram_bot!(vault_entry: "Other bot")
    [ {}, { SECRET => "guess" }, { SECRET => other.webhook_secret } ].each do |headers|
      post telegram_webhook_path(@bot), params: update(1003, chat: group, text: "Hi"), as: :json, headers: headers
      assert_response :not_found
    end
    post "/telegram/0", params: update(1003, chat: group, text: "Hi"), as: :json, headers: { SECRET => @bot.webhook_secret }
    assert_response :not_found
    assert_no_enqueued_jobs only: TelegramReceiveJob
  end

  test "attachments are listed with name, type and size, and telegram_file saves one on the agent's computer" do
    message = { document: { file_id: "BQACAgQAAx0-doc-file-id", file_name: "plan.pdf", mime_type: "application/pdf", file_size: 2_048 },
                photo: [ { file_id: "AgACAgQ-small-photo", file_size: 900, width: 90, height: 90 },
                         { file_id: "AgACAgQ-large-photo", file_size: 81_920, width: 1280, height: 960 } ] }
    post telegram_webhook_path(@bot), params: update(1004, chat: group, caption: "See attached.", reply_to_message: bot_post, **message), as: :json, headers: { SECRET => @bot.webhook_secret }
    perform_enqueued_jobs(only: TelegramReceiveJob)

    content = words(@submissions.sole["content"])
    assert_match "See attached.", content
    assert_match "plan.pdf (application/pdf, 2 KB), file id BQACAgQAAx0-doc-file-id", content
    assert_match "photo.jpg (image/jpeg, 80 KB), file id AgACAgQ-large-photo", content
    assert_no_match(/small-photo/, content, "only the largest size of a photo")
    assert_match "telegram_file", content

    stub_request(:post, "#{API}/getFile").with(body: { file_id: "BQACAgQAAx0-doc-file-id" }.to_json)
      .to_return(body: { ok: true, result: { file_id: "BQACAgQAAx0-doc-file-id", file_path: "documents/file_7.pdf", file_size: 2_048 } }.to_json)
    stub_request(:get, "https://api.telegram.org/file/bot#{TOKEN}/documents/file_7.pdf").to_return(body: "%PDF-1.7 plan")

    assert_equal "waiting", receive("telegram_file", { "file_id" => "BQACAgQAAx0-doc-file-id" }, call_id: "f1")[:status]
    perform_enqueued_jobs(only: InvocationCallJob)
    invocation = @conversation.invocations.find_by!(call_id: "f1")
    assert invocation.succeeded?, invocation.error
    assert_equal({ "name" => "file_7.pdf", "type" => "application/pdf", "size" => 2_048 }, invocation.result["file"])
    assert invocation.file?
    downloaded = invocation.download_file
    assert_equal "%PDF-1.7 plan", downloaded.respond_to?(:read) ? downloaded.read : downloaded
  end

  test "with approve-everything on, a send waits on a card with no every-call Always, and nothing is sent until the person allows it" do
    sent = stub_send(GROUP, "On it.")
    with_setting(:app, :approve_everything, true) do
      assert_equal "waiting", receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s1")[:status]
      invocation = @conversation.invocations.find_by!(call_id: "s1")
      assert invocation.awaiting_person?
      assert_equal [ "recipient" ], invocation.always_choices, "only Always for this chat (#150)"
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_not_requested sent

      assert_raises(ArgumentError, "no Always, even asked for") { invocation.approve!(by: @alice, always: "agent") }
      assert invocation.reload.awaiting_person?
      assert_empty @agent.permissions

      invocation.approve!(by: @alice)
      receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s1")
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_requested sent, times: 1
      assert_equal({ "sent" => true, "chat" => GROUP, "messageId" => 77 }, invocation.reload.result)
    end
  end

  test "an \"Always\" from before still asks, and so does an install that allows everything" do
    @agent.permissions.create!(tool_name: "telegram_send", granted_by: @alice)
    with_setting(:app, :approvals, "allow") do
      receive("telegram_send", { "chat" => GROUP, "text" => "Hello." }, call_id: "s2")
      assert @conversation.invocations.find_by!(call_id: "s2").awaiting_person?
    end
  end

  test "a declined send sends nothing" do
    sent = stub_send(GROUP, "On it.")
    receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s3")
    invocation = @conversation.invocations.find_by!(call_id: "s3")
    invocation.deny!(by: @alice)
    outcome = receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s3")
    perform_enqueued_jobs(only: InvocationCallJob)
    assert outcome[:isError]
    assert invocation.reload.denied?
    assert_not_requested sent
  end

  # A send Telegram may have taken is unknown, never failed: a failure is
  # what an agent sends again (#249).
  test "a send that times out is reported as unknown and never sent again" do
    sent = stub_request(:post, "#{API}/sendMessage").to_raise(Net::ReadTimeout)
    receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s4")
    @conversation.invocations.find_by!(call_id: "s4").approve!(by: @alice)
    receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s4")
    perform_enqueued_jobs(only: InvocationCallJob)

    invocation = @conversation.invocations.find_by!(call_id: "s4")
    assert invocation.succeeded?, invocation.error
    assert_equal GROUP, invocation.result["unknown"]
    assert_match(/unknown/i, invocation.result["note"])
    assert_match(/don't send it again/i, invocation.result["note"])
    assert_equal "unknown", invocation.dispatch.state

    3.times { receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s4") }
    travel(2.days) { Invocation.settle_abandoned }
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_requested sent, times: 1
    assert_equal "unknown", invocation.reload.dispatch.state
  end

  test "a send that Telegram refuses says why, and that nothing was sent" do
    stub_request(:post, "#{API}/sendMessage").to_return(status: 403, body: { ok: false, error_code: 403, description: "Forbidden: bot was blocked by the user" }.to_json)
    receive("telegram_send", { "chat" => 4242, "text" => "Hi." }, call_id: "s5")
    @conversation.invocations.find_by!(call_id: "s5").approve!(by: @alice)
    receive("telegram_send", { "chat" => 4242, "text" => "Hi." }, call_id: "s5")
    perform_enqueued_jobs(only: InvocationCallJob)
    error = @conversation.invocations.find_by!(call_id: "s5").error
    assert_match "bot was blocked by the user", error
    assert_match "nothing was sent", error
  end

  test "the token is read from the vault for each call and is never stored, logged or put in a command's arguments" do
    stub_send(GROUP, "On it.")
    logged = log do
      post telegram_webhook_path(@bot), params: update(1005, chat: group, text: "Book the train."), as: :json, headers: { SECRET => @bot.webhook_secret }
      perform_enqueued_jobs(only: TelegramReceiveJob)
      receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s6")
      @conversation.invocations.find_by!(call_id: "s6").approve!(by: @alice)
      receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s6")
      perform_enqueued_jobs(only: InvocationCallJob)
    end
    assert @conversation.invocations.find_by!(call_id: "s6").succeeded?

    secret_part = TOKEN.split(":").last
    assert_match "ARGS get resource --id 7f0c", passbolt_calls, "read from the vault, by the entry's id"
    assert_not_includes passbolt_calls, secret_part, "never in the password manager's arguments"
    assert_not_includes logged, secret_part
    assert_not_includes TelegramBot.connection.select_all("SELECT * FROM telegram_bots").to_a.to_json, secret_part
    assert_not_includes Invocation.connection.select_all("SELECT * FROM invocations").to_a.to_json, secret_part
    assert_not_includes @bot.reload.inspect, secret_part
  end

  test "an entry saved for another address, or not a bot token, is refused before anything is sent" do
    remove_fake_passbolt
    install_fake_passbolt(name: "Desk bot", uri: "https://bank.example/login", password: TOKEN)
    sent = stub_send(GROUP, "On it.")
    receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s7")
    @conversation.invocations.find_by!(call_id: "s7").approve!(by: @alice)
    receive("telegram_send", { "chat" => GROUP, "text" => "On it." }, call_id: "s7")
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_match "is saved for bank.example, not api.telegram.org", @conversation.invocations.find_by!(call_id: "s7").error
    assert_not_requested sent

    remove_fake_passbolt
    install_fake_passbolt(name: "Desk bot", uri: "https://api.telegram.org", password: "hunter2/../../evil")
    assert_raises(TelegramBot::SignInError) { @bot.say(GROUP, "On it.") }
    assert_not_requested :any, %r{api\.telegram\.org}
  end

  test "an agent has the Telegram tools only with a bot, and stays within the tool limit" do
    names = @agent.reload.conversation.tools.map(&:tool_name)
    assert_includes names, "telegram_send"
    assert_includes names, "telegram_file"
    assert_not_includes names, "telegram_messages", "looked up, so reading a chat costs no declared tool (#190, #249)"
    assert_includes @agent.own_tools.map(&:tool_name), "telegram_messages"
    assert_equal 23, @agent.own_tools.size, "one read tool, as on main: #249's reading folded into telegram_messages"
    with_bot = @agent.tool_count
    assert_equal 12, with_bot, "and the same number declared as before it"
    assert_operator with_bot, :<=, Agent::TOOL_LIMIT

    @bot.destroy!
    names = @agent.reload.conversation.tools.map(&:tool_name)
    assert_empty names.grep(/\Atelegram_/)
    assert_equal with_bot - 2, @agent.tool_count, "two declared tools, and only with a bot"

    @agent.create_telegram_bot!(vault_entry: "Desk bot")
    remove_fake_passbolt
    assert_empty @agent.reload.conversation.tools.map(&:tool_name).grep(/\Atelegram_/), "nor where it can't read the vault"

    assert Tool::TelegramSend.even_approving_everything?
    assert_not Tool::TelegramSend.always?
  end

  # Telegram's Bot API keeps no history for a bot, so a group's talk can be
  # read later only if the app kept it as it arrived (#190), whether or not
  # it woke the agent (#189).
  test "telegram_messages finds kept posts by their words and time, newest first, with sender and chat" do
    hear 2001, "The train leaves at nine.", at: Time.utc(2026, 11, 14, 9)
    hear 2002, "Book the train for Saturday.", at: Time.utc(2026, 11, 15, 9), from: { id: 43, first_name: "Sam" }
    hear 2003, "Who brings the snacks?", at: Time.utc(2026, 11, 15, 10)
    hear 2004, "Train tickets are booked.", at: Time.utc(2026, 11, 16, 9), chat: { id: -1009, type: "group", title: "Book club" }

    assert_empty @submissions, "none called on the bot, so none woke the agent (#189); all are kept"
    found = read_messages({ "query" => "train", "since" => "2026-11-15T00:00:00Z" })[:messages]

    assert_equal [ "Train tickets are booked.", "Book the train for Saturday." ], found.pluck(:text), "newest first, by words and time, in every chat"
    assert_equal [ "Maya Reyes", "Sam" ], found.pluck(:from)
    assert_equal [ { id: -1009, name: "Book club" }, { id: GROUP, name: "Weekend plans" } ], found.pluck(:chat)
    assert_equal Time.utc(2026, 11, 15, 9), Time.iso8601(found.last[:at])

    assert_equal [ "The train leaves at nine." ], read_messages({ "query" => "TRAIN", "until" => "2026-11-14T23:59:59Z" })[:messages].pluck(:text)
    assert_equal [ "Who brings the snacks?", "Book the train for Saturday." ],
      read_messages({ "chat" => "Weekend plans", "limit" => 2 })[:messages].pluck(:text), "one chat, by title, capped"
    assert_equal 3, read_messages({ "chat" => GROUP.to_s })[:messages].size, "one chat, by id"

    hear 2001, "The train leaves at nine.", at: Time.utc(2026, 11, 14, 9)
    assert_equal 4, read_messages({})[:messages].size, "kept once, however often Telegram posts it"
    assert_nil @conversation.invocations.last.approval, "reading asks no one"
  end

  test "telegram_messages never returns another agent's chat, even a group both bots are in" do
    bob = create_user(name: "Bob").agents.sole
    bobs_bot = bob.create_telegram_bot!(vault_entry: "Desk bot", username: "bob_example_bot")
    hear 2101, "Bob's bot was told the gate code.", bot: bobs_bot
    hear 2102, "Bob's bot heard about the gate.", bot: bobs_bot, chat: { id: -1007, type: "group", title: "Bob only" }
    hear 2103, "Our gate is blue."

    assert_equal [ "Our gate is blue." ], read_messages({ "query" => "gate" })[:messages].pluck(:text)
    assert_empty read_messages({ "chat" => GROUP.to_s, "query" => "code" })[:messages]
    refused = read_messages({ "chat" => "-1007" }, call_id: "m-bob")
    assert refused[:isError]
    assert_no_match(/Bob's bot/, refused.to_s)
  end

  test "telegram_messages is looked up, so no agent's declared tool count changes" do
    conversation = @agent.reload.conversation
    assert_equal %w[ telegram_file telegram_send ], conversation.tools.map(&:tool_name).grep(/\Atelegram_/).sort, "declared as before"
    assert_includes conversation.lookup_tools.map(&:tool_name), "telegram_messages"
    assert_includes conversation.tools.map(&:tool_name), "find_tools", "every agent already looks tools up"
    with_bot = @agent.tool_count

    @bot.destroy!
    assert_equal with_bot - 2, @agent.reload.tool_count, "a bot still adds only its two declared tools"
    assert_not_includes @agent.conversation.lookup_tools.map(&:tool_name), "telegram_messages"
    assert_nil Tool::TelegramMessages.asks
  end

  test "its vault entry is the app's to use, never the agent's to fill in or call an API with" do
    assert @agent.reserved_sign_in?("desk bot")
  end

  private
    def group = { id: GROUP, type: "supergroup", title: "Weekend plans" }

    def mentioning(words) = { text: "@desk_example_bot #{words}", entities: [ { type: "mention", offset: 0, length: 17 } ] }

    # A post the bot made, as Telegram quotes it in a reply.
    def bot_post = { message_id: 900, date: 1, chat: group, from: { id: 123456789, is_bot: true, first_name: "Desk", username: "desk_example_bot" }, text: "Which train?" }

    def update(id, chat:, from: { id: 42, is_bot: false, first_name: "Maya", last_name: "Reyes", username: "maya_r" }, **message)
      { update_id: id, message: { message_id: id, date: Time.utc(2026, 11, 16, 20).to_i, chat: chat, from: from, **message } }
    end

    # A post Telegram sends the bot, as its webhook takes it.
    def hear(id, text, at: Time.utc(2026, 11, 16, 20), bot: @bot, chat: group, **message)
      body = update(id, chat: chat, text: text, **message)
      body[:message][:date] = at.to_i
      post telegram_webhook_path(bot), params: body, as: :json, headers: { SECRET => bot.webhook_secret }
      assert_response :ok
      perform_enqueued_jobs(only: TelegramReceiveJob)
    end

    def read_messages(arguments, call_id: "m-#{SecureRandom.hex(4)}")
      outcome = receive("telegram_messages", arguments, call_id: call_id)
      outcome[:isError] ? outcome : outcome.fetch(:result)
    end

    def stub_send(chat, text)
      stub_request(:post, "#{API}/sendMessage").with(body: { chat_id: chat, text: text }.to_json, headers: { "Content-Type" => "application/json" })
        .to_return(body: { ok: true, result: { message_id: 77, chat: { id: chat }, date: 1 } }.to_json)
    end

    def receive(tool, arguments, call_id:, conversation: @conversation)
      payload = invocation_payload(conversation, tool: tool, arguments: arguments, call_id: call_id)
      Invocation.receive(conversation.reload, task_id: payload[:taskId], call_id: call_id, tool: tool,
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end

    def log
      output = StringIO.new
      capture = ActiveSupport::Logger.new(output, level: :debug)
      Rails.logger.broadcast_to(capture)
      yield
      output.string
    ensure
      Rails.logger.stop_broadcasting_to(capture)
    end
end
