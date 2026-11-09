require "application_system_test_case"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

# The README's walkthrough (docs/images/walkthrough-*.png), taken from a
# made-up person and agents so the pictures show the app as it is: an agent's
# settings, then one thread in which it works on its computer, emails and sets
# a routine, and asks another agent over Concourse. Taken at 1280x800 in light
# mode and a graphite accent, as the install sheet's are. Every run checks the
# pictures exist at that size; SCREENSHOTS=1 takes them again.
class ReadmeScreenshotsTest < ApplicationSystemTestCase
  include AgentTestHelper
  include EmailTestHelper

  SIZE = [ 1280, 800 ].freeze
  FRAMES = 4

  setup do
    install_sidecar_settings
    install_email_settings
    Rails.application.config.x.mail[:domain] = "example.org"
    @emails = Rails.application.config.x.access[:emails]
    Rails.application.config.x.access[:emails] = @emails + [ "sam@example.com" ]
    mock_ajent_auth(subject: "sam", email: "sam@example.com", name: "Sam")
    visit "/auth/ajent/callback"
    @user = User.find_by!(oidc_sub: "sam") # tenancy-ok: the test's own sign-in
    helper = @user.agents.sole
    name_agent(helper, "Grace Moreno")
    helper.update!(model: "anthropic/claude-sonnet-5-5", title: "Research Assistant")
    Agent.where(id: helper.id).update_all(email_name: "grace")
    create_conversation(helper, durable_id: "30").tap do
      it.messages.create!(entry_key: "1", entry_id: 1, role: "assistant", content: "The reading list for Thursday is ready: three papers, with notes.", created_at: 1.day.ago)
      it.update_columns(last_message_at: 1.day.ago, listed_at: 1.day.ago)
    end
    @agent = @user.agents.create!(name: "Ada Park", email_name: "ada", title: "Chief of Staff",
      model: "anthropic/claude-sonnet-5-5", instructions: INSTRUCTIONS)
    @conversation = create_conversation(@agent, durable_id: "31")
    stub_request(:get, "#{SIDECAR}/v1/models").to_return(status: 503, body: { error: "not_ready" }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+(\?.*)?\z}).to_return(body: { status: "idle", failure: nil, pendingInputs: [] }.to_json)
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/\d+/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    Rails.application.config.x.access[:emails] = @emails
    remove_email_settings
    remove_sidecar_settings
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "the README's walkthrough is the app at 1280x800" do
    [ [ 1, nil ], [ 2, :works_on_its_computer ], [ 3, :emails_and_sets_a_routine ], [ 4, :asks_another_agent ] ].each do |frame, part|
      send(part) if part
      take(frame) if ENV["SCREENSHOTS"]
    end
    1.upto(FRAMES) do |frame|
      path = Rails.root.join("docs/images/walkthrough-#{frame}.png")
      assert_equal SIZE, path.binread.byteslice(16, 8).unpack("N2"), "#{path} is not #{SIZE.join("x")}; run SCREENSHOTS=1 bin/rails test #{__FILE__}"
    end
  end

  private
    INSTRUCTIONS = <<~MARKDOWN.freeze
      You are Ada Park, chief of staff to Sam.

      - Find public data, fetch it on your computer and check it before you report.
      - Say where every number came from.
      - Keep summaries short: the answer first, then the detail.
    MARKDOWN

    SURVEY = "https://data.example.org/street-trees.csv".freeze

    # The thread grows a part at a time, and each picture is taken as it stands then, at its latest turn.
    def works_on_its_computer
      @start = 2.hours.ago
      say "user", "Could you download the street tree survey from data.example.org and tell me which species are most common?", @start
      ran @start + 20.seconds, bash("b1", "curl -sSLO #{SURVEY} && wc -l street-trees.csv"), "4812 street-trees.csv"
      ran @start + 40.seconds, bash("b2", "tail -n +2 street-trees.csv | cut -d, -f3 | sort | uniq -c | sort -rn | head -5"),
        "    912 London plane\n    640 Red maple\n    518 Honey locust\n    401 Little-leaf linden\n    377 Pin oak"
      say "assistant", "The survey lists 4,811 trees. The most common are **London plane** (912), **red maple** (640) and **honey locust** (518).",
        @start + 1.minute
    end

    def emails_and_sets_a_routine
      say "user", "Thanks. Email me that, and send me a fresh count every weekday at 8am.", @start + 30.minutes
      ledger @start + 31.minutes,
        [ "e1", "send_email", { "to" => [ "sam@example.com" ], "subject" => "Street trees: the most common species",
            "body" => "London plane 912, red maple 640, honey locust 518, little-leaf linden 401, pin oak 377." },
          { "sent" => [ "sam@example.com" ], "messageId" => "<summary-1@example.org>" } ],
        [ "r1", "add_routine", { "schedule" => "every weekday at 8am",
            "prompt" => "Download #{SURVEY} again, count the species and email Sam the top five." },
          { "id" => 1, "schedule" => "every weekday at 8am", "nextRun" => "2026-11-10T08:00:00Z" } ]
      say "assistant", "Sent to sam@example.com. Every weekday at 8am I'll count them again and email you.", @start + 32.minutes
    end

    def asks_another_agent
      say "user", "Can you ask acme/noor to check the counts?", @start + 50.minutes
      ledger @start + 51.minutes,
        [ "s1", "concourse_send", { "to" => "acme/noor", "text" => "Could you check my species counts for #{SURVEY}?" },
          { "taskId" => "task-7", "state" => "TASK_STATE_SUBMITTED", "note" => "Sent. The answer will come to you as a new message." } ]
      say "user", Conversation.received("Checked: 4,811 rows, and your counts match mine.",
        from: "acme/noor, task task-7, which you sent", via: "Concourse mail", answer: "It is settled: TASK_STATE_COMPLETED."), @start + 58.minutes
      say "assistant", "acme/noor checked the counts, and they match.", @start + 59.minutes
    end

    def say(role, content, at, **attributes)
      entry = @conversation.messages.maximum(:entry_id).to_i + 1
      @conversation.messages.create!(entry_key: entry.to_s, entry_id: entry, role:, content:, created_at: at, **attributes)
      # The agent list's time is the thread's last news, as it would have been then.
      @conversation.update_columns(last_message_at: at, listed_at: at)
    end

    def bash(id, command) = { "id" => id, "name" => "bash", "arguments" => { "command" => command } }

    # A sidecar tool's call and its result, as Conversation#sync! keeps them.
    def ran(at, call, output)
      say "assistant", "", at, tool_calls: [ call ]
      say "toolResult", output, at + 5.seconds, tool_name: call["name"], tool_call_id: call["id"]
    end

    # The agent's own tools: the ledger's rows (Invocation), each answered.
    def ledger(at, *calls)
      say "assistant", "", at, tool_calls: calls.map { |id, name, arguments, _| { "id" => id, "name" => name, "arguments" => arguments } }
      calls.each do |id, name, arguments, result|
        @conversation.invocations.create!(task_id: "7", call_id: id, tool_name: name, arguments:, result:, state: "succeeded",
          digest: Invocation.digest_for(@conversation, task_id: "7", call_id: id, tool: name, arguments:))
        say "toolResult", result.to_json, at + 5.seconds, tool_name: name, tool_call_id: id
      end
    end

    OPENED = { 2 => "Ran bash", 3 => "Ran add routine", 4 => "Ran concourse send" }.freeze

    def take(frame)
      shoot(frame) do
        if frame == 1
          visit agent_path(@agent)
          assert_selector "h1", text: "Ada Park"
        else
          visit conversation_path(@conversation)
          assert_text @conversation.messages.where(role: "assistant").last.content.delete("*")
          # Its latest tool row opened, as a click opens it, and the thread at its latest turn.
          page.execute_script(<<~JS, OPENED.fetch(frame))
            const traces = [ ...document.querySelectorAll('#messages details.ui-trace') ]
            traces.findLast(it => it.querySelector('summary').textContent.trim() === arguments[0]).open = true
            document.querySelector('#messages').lastElementChild.scrollIntoView({ block: 'end' })
          JS
        end
      end
    end

    def shoot(frame)
      page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: SIZE[0], height: SIZE[1], deviceScaleFactor: 1, mobile: false)
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [ { name: "prefers-color-scheme", value: "light" } ])
      yield
      assert_no_selector ".flash, [role=alert]"
      page.execute_script("document.documentElement.style.setProperty('--brand', 'oklch(0.34 0 0)'); document.documentElement.style.setProperty('--ring', 'oklch(0.55 0 0)'); document.activeElement.blur()")
      sleep 0.5 # the view transition and the header's shadow settle
      Rails.root.join("docs/images").mkpath
      page.save_screenshot(Rails.root.join("docs/images/walkthrough-#{frame}.png").to_s)
    ensure
      page.driver.browser.execute_cdp("Emulation.clearDeviceMetricsOverride")
      page.driver.browser.execute_cdp("Emulation.setEmulatedMedia", features: [])
    end
end
