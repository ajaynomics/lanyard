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
    names = %w[ list_saved_sign_ins sign_in_with_saved_password ]
    assert_equal names, @agent.tools.map(&:tool_name) & names

    with_setting(:passbolt, :url, nil) { assert_empty @agent.reload.tools.map(&:tool_name) & names }
    @agent.computer.update!(provider: "local")
    assert_empty @agent.reload.tools.map(&:tool_name) & names, "no screen, nothing to sign in on"
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

  test "the person approves, the sidecar collects the password once, and the model never sees it" do
    log = capture_log do
      assert_equal "waiting", invoke("sign_in_with_saved_password", { "name" => "Bank" })["status"]
      assert_empty passbolt_calls, "nothing is looked up before the person answers"

      invocation = @conversation.invocations.sole
      invocation.approve!(by: @alice)
      invoke("sign_in_with_saved_password", { "name" => "Bank" })
      perform_enqueued_jobs(only: InvocationCallJob)

      done = invoke("sign_in_with_saved_password", { "name" => "Bank" })
      assert_equal({ "status" => "done", "result" => { "signIn" => "Bank", "site" => "https://bank.example/login" }, "isError" => false, "fill" => true }, done)

      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :ok
      assert_equal({ "host" => "bank.example", "username" => "maya", "password" => PASSWORD }, response.parsed_body)
      assert_equal "no-store", response.headers["Cache-Control"]

      post "/agent/sign_ins", params: redeem, headers: rails_bearer, as: :json
      assert_response :gone

      assert_not_includes invocation.reload.attributes.to_json, PASSWORD
      assert_not_includes invoke("sign_in_with_saved_password", { "name" => "Bank" }).to_json, PASSWORD
    end
    assert_match "Sidecar::SignInsController#create", log, "the log was read"
    assert_not_includes log, PASSWORD
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

  test "the app reaches the vault inside the host: by default the accessory's container, never the public address" do
    with_setting(:passbolt, :url, nil) do
      with_kamal(container: "maya-web-production-6f1c2a", destination: "production", version: "6f1c2a") do
        assert_equal "http://maya-passbolt", DurableAssistants::Passbolt.url
      end
      with_kamal(container: "my-assistants-job-6f1c2a", destination: nil, version: "6f1c2a") do
        assert_equal "http://my-assistants-passbolt", DurableAssistants::Passbolt.url, "a service with a dash, no destination"
      end
      with_kamal(container: nil, destination: nil, version: nil) do
        assert_nil DurableAssistants::Passbolt.url, "outside Kamal there is no default"
        assert_not DurableAssistants::Passbolt.configured?
      end
    end
    with_kamal(container: "maya-web-production-6f1c2a", destination: "production", version: "6f1c2a") do
      assert_equal "https://passwords.example", DurableAssistants::Passbolt.url, "a setting wins"
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
    def with_kamal(container:, destination:, version:)
      names = { "KAMAL_CONTAINER_NAME" => container, "KAMAL_DESTINATION" => destination, "KAMAL_VERSION" => version }
      previous = names.keys.index_with { ENV[it] }
      names.each { |name, value| ENV[name] = value }
      yield
    ensure
      previous.each { |name, value| ENV[name] = value }
    end

    def invoke(tool, arguments, call_id: "toolu_1")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: call_id),
        headers: rails_bearer, as: :json
      response.parsed_body
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
