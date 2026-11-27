require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# Saved sign-ins (docs/passwords.md): the install's password manager, shared
# with the agents' one user. The model can list what is shared and ask to use
# one; the person approves each use; the password goes to the sidecar once,
# for the browser, and never into the model's result, the ledger or the logs.
class SavedSignInsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper
  include PassboltTestHelper

  setup do
    install_sidecar_settings
    install_fake_passbolt
    @alice = create_user(name: "Alice")
    @agent = @alice.agents.sole
    @agent.create_computer!(provider: "sprites", state: "on")
    @conversation = create_conversation(@agent)
  end
  teardown do
    remove_fake_passbolt
    remove_sidecar_settings
  end

  test "an agent with a screen has the two tools only where the install has a password manager" do
    names = %w[ list_saved_sign_ins sign_in_with_saved_password ask_for_sign_in ]
    assert_equal names, @agent.conversation.tools.map(&:tool_name) & names

    with_setting(:passbolt, :url, nil) { assert_empty @agent.reload.conversation.tools.map(&:tool_name) & names }
    @agent.computer.update!(provider: "local")
    assert_empty @agent.reload.conversation.tools.map(&:tool_name) & names, "no screen, nothing to sign in on"
  end

  test "listing gives names and sites, and the key and passphrase reach the command only in its environment" do
    invoke("list_saved_sign_ins", {})
    perform_enqueued_jobs(only: InvocationCallJob)

    assert_equal({ "signIns" => [ { "name" => "Bank", "site" => "https://bank.example/login" } ] }, invoke("list_saved_sign_ins", {})["result"])
    assert_match "ARGS list resource --column id --column name --column uri --json --mfaMode none", passbolt_calls
    assert_match(/^SERVERADDRESS$/, passbolt_calls)
    assert_match(/^USERPRIVATEKEY$/, passbolt_calls)
    assert_match(/^USERPASSWORD$/, passbolt_calls)
    assert_no_match PASSPHRASE, passbolt_calls
  end

  # A sign-in its own mail or calendar account uses is for the app alone:
  # filled into the same host's webmail, a mailbox's password would send
  # around the forced Bcc and every approval. Matched as the vault finds a
  # name, whatever its case.
  test "a sign-in the agent's own mail account uses is neither listed, filled, nor handed to the sidecar" do
    invoke("sign_in_with_saved_password", { "name" => "Bank" })
    invocation = @conversation.invocations.sole
    invocation.approve!(by: @alice)
    invoke("sign_in_with_saved_password", { "name" => "Bank" })
    perform_enqueued_jobs(only: InvocationCallJob)
    @agent.create_mail_account!(address: "desk@bank.example", smtp_host: "bank.example", vault_entry: "bank")

    post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    assert_response :gone, "a fill approved before the account took the sign-in gets no password"

    invoke("list_saved_sign_ins", {}, call_id: "toolu_list")
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal({ "signIns" => [] }, invoke("list_saved_sign_ins", {}, call_id: "toolu_list")["result"])

    refused = invoke("sign_in_with_saved_password", { "name" => "BANK" }, call_id: "toolu_2")
    assert_equal "done", refused["status"]
    assert refused["isError"]
    assert_match "belongs to your own mail or calendar account, so it can't be filled in a browser", refused.to_json
    assert_not_includes response.body, PASSWORD
  end

  test "a sign-in the agent's calendar server or linked calendar uses is held back the same way" do
    @agent.create_calendar_server!(url: "https://bank.example/dav/calendars/maya/", vault_entry: "Bank")
    invoke("list_saved_sign_ins", {})
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal({ "signIns" => [] }, invoke("list_saved_sign_ins", {})["result"])

    @agent.calendar_server.destroy!
    @agent.update!(linked_calendar_server: "https://bank.example/dav/", linked_calendar: "family", linked_calendar_entry: "Bank")
    refused = invoke("sign_in_with_saved_password", { "name" => "Bank" }, call_id: "toolu_3")
    assert refused["isError"]
    assert_match "can't be filled in a browser", refused.to_json
  end

  test "the person approves, the sidecar collects the password once, and the model never sees it" do
    log = capture_log do
      assert_equal "waiting", invoke("sign_in_with_saved_password", { "name" => "Bank" })["status"]
      assert_empty passbolt_calls, "nothing is looked up before the person answers"

      invocation = @conversation.invocations.sole
      invocation.approve!(by: @alice)
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      perform_enqueued_jobs(only: InvocationCallJob)

      done = invoke("sign_in_with_saved_password", { "name" => "Bank" })
      assert_equal({ "status" => "done", "result" => { "signIn" => "Bank", "site" => "https://bank.example/login", "step" => "sign_in" }, "isError" => false, "fill" => true }, done)

      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :ok
      assert_equal({ "host" => "bank.example", "username" => "maya", "password" => PASSWORD, "account" => nil }, response.parsed_body,
        "an entry with no account line has none")
      assert_equal "no-store", response.headers["Cache-Control"]

      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :gone

      assert_not_includes invocation.reload.attributes.to_json, PASSWORD
      assert_not_includes invoke("sign_in_with_saved_password", { "name" => "Bank" }).to_json, PASSWORD
    end
    assert_match "Sidecar::SignInsController#create", log, "the log was read"
    assert_not_includes log, PASSWORD
  end

  # A site that asks for an account number besides the username (a bank's
  # Account Number, User ID and Password): the vault keeps it as a line
  # "Account: ..." in the entry's encrypted description, and it goes to the
  # sidecar with the password, and nowhere else.
  test "an account line in the entry's description goes to the sidecar with the password, and the model never sees it" do
    remove_fake_passbolt
    install_fake_passbolt(description: "Branch: Main Street\nACCOUNT:   12345  \nAccount: 99999")
    log = capture_log do
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      @conversation.invocations.sole.approve!(by: @alice)
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      perform_enqueued_jobs(only: InvocationCallJob)
      done = invoke("sign_in_with_saved_password", { "name" => "Bank" })
      assert_equal({ "signIn" => "Bank", "site" => "https://bank.example/login", "step" => "sign_in" }, done["result"])

      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :ok
      assert_equal({ "host" => "bank.example", "username" => "maya", "password" => PASSWORD, "account" => "12345" }, response.parsed_body,
        "the first account line, its key in any case, its value trimmed")
      assert_no_match "Branch", response.body, "nothing else of the description"

      assert_not_includes @conversation.invocations.sole.reload.attributes.to_json, "12345"
      assert_not_includes invoke("sign_in_with_saved_password", { "name" => "Bank" }).to_json, "12345"
      assert_not_includes DurableAssistants::Passbolt.sign_in(@agent, "7f0c").inspect, "12345"
    end
    assert_not_includes log, "12345"
  end

  # A site's form to set a new password (an API password, say) has a box for it
  # and one to confirm it, and will not save until both match.
  test "the agent can name the password boxes to fill, a confirm box too; the names reach the sidecar and the password stays out of the ledger" do
    arguments = { "name" => "Bank", "password_fields" => [ "#new_password", "#confirm_password" ] }
    log = capture_log do
      assert_equal "waiting", invoke("sign_in_with_saved_password", arguments)["status"], "asked first, as before"
      @conversation.invocations.sole.approve!(by: @alice)
      invoke("sign_in_with_saved_password", arguments)
      perform_enqueued_jobs(only: InvocationCallJob)

      done = invoke("sign_in_with_saved_password", arguments)
      assert_equal({ "signIn" => "Bank", "site" => "https://bank.example/login", "step" => "sign_in",
        "passwordFields" => [ "#new_password", "#confirm_password" ] }, done["result"])
      assert done["fill"]

      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_equal PASSWORD, response.parsed_body["password"]

      assert_not_includes @conversation.invocations.sole.reload.attributes.to_json, PASSWORD
      assert_not_includes invoke("sign_in_with_saved_password", arguments).to_json, PASSWORD
    end
    assert_not_includes log, PASSWORD
  end

  # A sandboxed agent's own browser on the host, named by the install's map (agent/fill-socket.mjs).
  test "the sidecar is told which browser to fill for an agent the install gives its own browser" do
    @agent = @alice.start_agent("Avery", email_name: "avery")
    @agent.create_computer!(provider: "local", state: "on")
    @conversation = create_conversation(@agent, durable_id: "13")
    with_setting(:pi_durable, :sandbox_browsers, "999=blake.b, #{@agent.id}=avery-browser") do
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      @conversation.invocations.sole.approve!(by: @alice)
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_equal({ "signIn" => "Bank", "site" => "https://bank.example/login", "step" => "sign_in", "browser" => "avery-browser" },
        invoke("sign_in_with_saved_password", { "name" => "Bank" })["result"])
      assert_nil @alice.start_agent("Avery B", email_name: "avery-b").sandbox_browser, "unmapped: never its email name"
      assert_nil Agent.new(id: 999).sandbox_browser, "a name the host's browsers can't have"
    end
  end

  # One browser per agent: with a desktop the person sees, the fill goes to the
  # tab visit_website opened there, never to a sandbox browser nobody looks at.
  test "an agent with a desktop is filled there, even where the install also gives it its own browser" do
    with_setting(:pi_durable, :sandbox_browsers, "#{@agent.id}=avery-browser") do
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      @conversation.invocations.sole.approve!(by: @alice)
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_equal({ "signIn" => "Bank", "site" => "https://bank.example/login", "step" => "sign_in" },
        invoke("sign_in_with_saved_password", { "name" => "Bank" })["result"])
    end
  end

  test "password boxes are named for the sign-in step only, a few at most" do
    tool = Tool::SignInWithSavedPassword
    assert_empty tool.errors_for("name" => "Bank", "password_fields" => [ "#a", "#b" ])
    assert_not_empty tool.errors_for("name" => "Bank", "password_fields" => [])
    assert_not_empty tool.errors_for("name" => "Bank", "password_fields" => Array.new(5) { "#box#{it}" })

    arguments = { "name" => "Bank", "step" => "security_question", "password_fields" => [ "#a" ] }
    invoke("sign_in_with_saved_password", arguments)
    @conversation.invocations.sole.approve!(by: @alice)
    invoke("sign_in_with_saved_password", arguments)
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal({ "error" => Tool::SignInWithSavedPassword::FIELDS_ON_QUESTION }, invoke("sign_in_with_saved_password", arguments)["result"])
  end

  test "a security question's step carries no account" do
    remove_fake_passbolt
    install_fake_passbolt(description: "Account: 12345")
    arguments = { "name" => "Bank", "step" => "security_question" }
    invoke("sign_in_with_saved_password", arguments)
    @conversation.invocations.sole.approve!(by: @alice)
    invoke("sign_in_with_saved_password", arguments)
    perform_enqueued_jobs(only: InvocationCallJob)
    invoke("sign_in_with_saved_password", arguments)

    post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    assert_not_includes response.body, "12345"
  end

  test "a security question's step gives the sidecar the saved answers and no password, once, and the model neither" do
    log = capture_log do
      arguments = { "name" => "Bank", "step" => "security_question" }
      invoke("sign_in_with_saved_password", arguments)
      @conversation.invocations.sole.approve!(by: @alice)
      invoke("sign_in_with_saved_password", arguments)
      perform_enqueued_jobs(only: InvocationCallJob)

      done = invoke("sign_in_with_saved_password", arguments)
      assert_equal({ "signIn" => "Bank", "site" => "https://bank.example/login", "step" => "security_question" }, done["result"])
      assert done["fill"]

      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_equal({ "host" => "bank.example", "answers" => [ { "question" => QUESTION, "answer" => ANSWER } ] }, response.parsed_body)
      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :gone

      assert_not_includes @conversation.invocations.sole.attributes.to_json, ANSWER
      assert_not_includes invoke("sign_in_with_saved_password", arguments).to_json, ANSWER
    end
    assert_not_includes log, ANSWER
    assert_not_includes log, PASSWORD
  end

  test "the sign-in step gives the password and none of the answers" do
    invoke("sign_in_with_saved_password", { "name" => "Bank" })
    @conversation.invocations.sole.approve!(by: @alice)
    invoke("sign_in_with_saved_password", { "name" => "Bank" })
    perform_enqueued_jobs(only: InvocationCallJob)
    invoke("sign_in_with_saved_password", { "name" => "Bank" })

    post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    assert_not_includes response.body, ANSWER
  end

  test "a denied, unapproved or stale call has no password to collect" do
    invoke("sign_in_with_saved_password", { "name" => "Bank" })
    post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    assert_response :gone

    @conversation.invocations.sole.approve!(by: @alice)
    invoke("sign_in_with_saved_password", { "name" => "Bank" })
    perform_enqueued_jobs(only: InvocationCallJob)
    travel Tool::SignInWithSavedPassword::FILL_WITHIN + 1.minute do
      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :gone
    end

    post "/agent/sign_ins", params: redeem, headers: rails_bearer(SIDECAR_TOKEN), as: :json
    assert_response :unauthorized
  end

  test "a password manager that fails or answers too late leaves the approval to collect again, once" do
    approve_sign_in
    remove_fake_passbolt
    install_fake_passbolt(fail: true)
    post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    assert_response :bad_gateway
    assert_not @conversation.invocations.sole.result.key?("filled"), "a failure spends nothing"
    remove_fake_passbolt
    install_fake_passbolt

    while_fetching(-> { travel Tool::SignInWithSavedPassword::FETCH_WITHIN + 1.second }) do
      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    end
    assert_response :gone, "an answer later than the sidecar waits is not handed over"

    post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    assert_response :ok
    assert_equal PASSWORD, response.parsed_body["password"]
    post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    assert_response :gone
  end

  test "of two collections at once only one gets the password" do
    approve_sign_in
    invocation = @conversation.invocations.sole
    asked, other = false, nil
    while_fetching(-> { next if asked; asked = true; other = Invocation.find(invocation.id).redeem_sign_in }) do
      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
    end
    assert_equal PASSWORD, other&.password, "the one asked while the first was fetching"
    assert_response :gone
  end

  # Listing the vault is most of a fetch's wait, so the entry's id is kept.
  test "a second sign-in by the same name reads its one entry without listing the vault again" do
    cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    %w[ toolu_1 toolu_2 ].each do |call_id|
      invoke("sign_in_with_saved_password", { "name" => "Bank" }, call_id:)
      @conversation.invocations.find_by!(call_id:).approve!(by: @alice)
      invoke("sign_in_with_saved_password", { "name" => "Bank" }, call_id:)
      perform_enqueued_jobs(only: InvocationCallJob)
      File.write(@passbolt_calls, "")
      post "/agent/sign_ins", params: redeem(call_id:), headers: rails_bearer, as: :json
      assert_equal PASSWORD, response.parsed_body["password"]
    end

    assert_equal [ 0, 1 ], [ passbolt_calls.scan(/^ARGS list /).size, passbolt_calls.scan(/^ARGS get /).size ]
  ensure
    Rails.cache = cache
  end

  test "on an install that allows everything no password can be collected before approval" do
    with_setting(:app, :approvals, "allow") do
      assert_equal "waiting", invoke("sign_in_with_saved_password", { "name" => "Bank" })["status"]
      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :gone
    end
  end

  test "a key whose newlines came escaped, as Kamal passes a multi-line secret, reaches the command armored again" do
    Rails.application.config.x.passbolt[:private_key] = PRIVATE_KEY.gsub("\n", "\\n")
    invoke("list_saved_sign_ins", {})
    perform_enqueued_jobs(only: InvocationCallJob)

    assert_match "KEY LINES 3", passbolt_calls
  end

  test "an unknown name or a failing password manager is a refusal that carries no secret" do
    invoke("sign_in_with_saved_password", { "name" => "Elsewhere" }, call_id: "toolu_a")
    @conversation.invocations.sole.approve!(by: @alice)
    invoke("sign_in_with_saved_password", { "name" => "Elsewhere" }, call_id: "toolu_a")
    perform_enqueued_jobs(only: InvocationCallJob)
    assert_equal({ "error" => "Nothing called Elsewhere is shared with the agents." },
      invoke("sign_in_with_saved_password", { "name" => "Elsewhere" }, call_id: "toolu_a")["result"])

    remove_fake_passbolt
    install_fake_passbolt(fail: true)
    invoke("list_saved_sign_ins", {}, call_id: "toolu_b")
    perform_enqueued_jobs(only: InvocationCallJob)
    refused = invoke("list_saved_sign_ins", {}, call_id: "toolu_b")
    assert_equal({ "error" => "The password manager could not be reached." }, refused["result"])
  end

  test "asked for a sign-in, the person types it into their page; it goes to the vault, and the agent learns only that it was saved" do
    arguments = { "name" => "Library", "site" => "https://library.example/login", "why" => "To renew your books." }
    sign_in_as(@alice)
    log = capture_log do
      assert_equal "waiting", invoke("ask_for_sign_in", arguments)["status"]
      invocation = @conversation.invocations.sole

      card = Nokogiri::HTML(ApplicationController.render(partial: "invocations/invocation", locals: { invocation: invocation }))
      form = card.at_css("form[action='#{conversation_invocation_sign_in_path(@conversation, invocation)}']")
      assert form.at_css("input[type=password][autocomplete=new-password]")
      assert_match "To renew your books.", card.text

      # Its own page, which the line above the box links to, has the same form.
      get approval_path(invocation)
      assert_select "form[action=?] input[type=password][autocomplete=new-password]", conversation_invocation_sign_in_path(@conversation, invocation)

      post conversation_invocation_sign_in_path(@conversation, invocation), params: { sign_in: { username: "maya", password: "" } }
      assert invocation.reload.awaiting_person?, "a blank password saves nothing"

      post conversation_invocation_sign_in_path(@conversation, invocation), params: { sign_in: { username: "maya", password: PASSWORD } }
      assert_redirected_to conversation_path(@conversation)
      assert_match %(SAVE INPUT {"name":"Library","uri":"https://library.example/login","username":"maya","password":"#{PASSWORD}"}), passbolt_calls
      assert_match(/^SAVE ARGS $/, passbolt_calls, "the password goes on standard input, never in the arguments")

      done = invoke("ask_for_sign_in", arguments)
      assert_equal({ "status" => "done", "result" => { "saved" => "Library", "site" => "https://library.example/login" }, "isError" => false }, done)
      assert_not_includes invocation.reload.attributes.to_json, PASSWORD
      assert_not_includes Approval.where(invocation: invocation).to_a.to_json, PASSWORD # tenancy-ok: reached through the invocation

      post conversation_invocation_sign_in_path(@conversation, invocation), params: { sign_in: { username: "x", password: "y" } }
      assert_equal "That request has already been answered or has expired.", flash[:alert]
    end
    assert_match "SignInsController#create", log, "the log was read"
    assert_not_includes log, PASSWORD
  end

  test "a name already saved is refused and nothing is written; declining tells the agent so" do
    sign_in_as(@alice)
    invoke("ask_for_sign_in", { "name" => "bank", "site" => "https://bank.example/" })
    invocation = @conversation.invocations.sole
    post conversation_invocation_sign_in_path(@conversation, invocation), params: { sign_in: { username: "u", password: PASSWORD } }
    assert_match "already saved", flash[:alert]
    assert_no_match "SAVE", passbolt_calls
    assert invocation.reload.awaiting_person?

    post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "approve" }
    assert invocation.reload.awaiting_person?, "a sign-in is approved only by saving it"

    post conversation_invocation_approval_path(@conversation, invocation), params: { decision: "deny" }
    assert invoke("ask_for_sign_in", { "name" => "bank", "site" => "https://bank.example/" })["isError"]
  end

  test "another person cannot answer the request" do
    invoke("ask_for_sign_in", { "name" => "Library", "site" => "https://library.example/" })
    sign_in_as(create_user(name: "Mallory"), email: "member@example.com")
    post conversation_invocation_sign_in_path(@conversation, @conversation.invocations.sole), params: { sign_in: { username: "u", password: "p" } }
    assert_response :not_found
    assert_no_match "SAVE", passbolt_calls
  end

  test "an agent with its own Passbolt user reads and saves as that user, its key a pair, kept encrypted; another agent stays the shared user" do
    @agent.update!(passbolt_private_key: "-----BEGIN PGP PRIVATE KEY BLOCK-----\njordan\n-----END PGP PRIVATE KEY BLOCK-----",
      passbolt_passphrase: "jordan-own-passphrase")
    assert_no_match "jordan-own-passphrase", Agent.connection.select_value("SELECT passbolt_passphrase FROM agents WHERE id = #{@agent.id}")
    DurableAssistants::Passbolt.sign_ins(@agent)
    assert_equal [ "AS another user" ], passbolt_calls.lines.grep(/^AS /).map(&:strip)

    other = @alice.start_agent("Casey")
    DurableAssistants::Passbolt.sign_ins(other)
    @agent.update!(passbolt_passphrase: nil)
    DurableAssistants::Passbolt.sign_ins(@agent)
    assert_equal [ "AS another user", "AS the shared user", "AS the shared user" ], passbolt_calls.lines.grep(/^AS /).map(&:strip),
      "half a pair is no key of its own"

    with_setting(:passbolt, :private_key, nil) do
      assert_not DurableAssistants::Passbolt.configured?(other)
      @agent.update!(passbolt_passphrase: "jordan-own-passphrase")
      assert DurableAssistants::Passbolt.configured?(@agent), "an agent's own user needs no shared one"
      assert_includes @agent.reload.conversation.tools.map(&:tool_name), "list_saved_sign_ins"
    end
  end

  test "the app reaches the vault inside the host: by default the accessory's container, never the public address" do
    with_setting(:passbolt, :url, nil) do
      with_kamal(container: "acme-web-production-6f1c2a", destination: "production", version: "6f1c2a") do
        assert_equal "http://acme-passbolt", DurableAssistants::Passbolt.url
      end
      with_kamal(container: "my-assistants-job-6f1c2a", destination: nil, version: "6f1c2a") do
        assert_equal "http://my-assistants-passbolt", DurableAssistants::Passbolt.url, "a service with a dash, no destination"
      end
      with_kamal(container: nil, destination: nil, version: nil) do
        assert_nil DurableAssistants::Passbolt.url, "outside Kamal there is no default"
        assert_not DurableAssistants::Passbolt.configured?(@agent)
      end
    end
    with_kamal(container: "acme-web-production-6f1c2a", destination: "production", version: "6f1c2a") do
      assert_equal "http://passwords.example", DurableAssistants::Passbolt.url, "a setting wins"
    end
  end

  # The computer is a remote machine off the host's network: it gets one
  # password, typed into its browser, and nothing that reaches the vault.
  test "nothing on the computer side, nor the sidecar, needs the vault" do
    computer = %w[ Dockerfile.agent agent/sprite-relay.mjs ] + Dir[Rails.root.join("agent/guest/**/*")].select { File.file?(it) }
    sidecar = Dir[Rails.root.join("agent/*.mjs")] + %w[ bin/agent bin/agent-container ]
    (computer + sidecar).each do |path|
      assert_no_match(/passbolt|USERPRIVATEKEY|USERPASSWORD|SERVERADDRESS/i, Rails.root.join(path).read, "#{path} mentions the vault")
    end
    assert_no_match(/PASSBOLT/, Rails.root.join("bin/agent").read, "the sidecar is never handed the vault's settings")
  end

  private
    # Admission knows the test's two addresses; the person is found by subject.
    def sign_in_as(user, email: "operator@example.com") = sign_in_via_ajent(subject: user.oidc_sub, email: email, name: user.name)

    def invoke(tool, arguments, call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
    end

    def approve_sign_in
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      @conversation.invocations.sole.approve!(by: @alice)
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      perform_enqueued_jobs(only: InvocationCallJob)
    end

    # Runs before each fetch from the password manager, standing in for what
    # happens while it is slow to answer.
    def while_fetching(meanwhile)
      fetch = DurableAssistants::Passbolt.method(:sign_in)
      DurableAssistants::Passbolt.define_singleton_method(:sign_in) { |*arguments| meanwhile.call.then { fetch.call(*arguments) } }
      yield
    ensure
      DurableAssistants::Passbolt.define_singleton_method(:sign_in, fetch)
    end

    def redeem(call_id: "toolu_1")
      payload = invocation_payload(@conversation, tool: "sign_in_with_saved_password", arguments: { "name" => "Bank" }, call_id: call_id)
      payload.slice(:actorId, :workspaceId, :conversationId, :taskId, :callId)
    end

    def capture_log
      output = StringIO.new
      logger = ActiveSupport::Logger.new(output)
      previous = Rails.logger
      Rails.logger = ActiveSupport::BroadcastLogger.new(previous, logger)
      ActionController::Base.logger = Rails.logger
      yield
      output.string
    ensure
      Rails.logger = previous
      ActionController::Base.logger = previous
    end
end
