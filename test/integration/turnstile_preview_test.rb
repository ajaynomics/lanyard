require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class TurnstilePreviewTest < ActionDispatch::IntegrationTest
  include AgentTestHelper, ActiveJob::TestHelper

  TOOL = "create_turnstile_preview"
  HOSTNAME = "preview.example.net"
  ACCOUNT = "a" * 32
  RESOURCE = "00000000-0000-4000-8000-000000000008"
  ENDPOINT = "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT}/challenges/widgets"
  PROJECT = "preview-studio"
  PROJECT_ID = "00000000-0000-4000-8000-000000000009"
  PAGES = "https://api.cloudflare.com/client/v4/accounts/#{ACCOUNT}/pages/projects/#{PROJECT}"
  PAGES_BEARER = "synthetic-pages-preview-bearer"
  PAGES_RESOURCE = "38b1bd70-cb26-4dce-9c15-abc012ebbb90"
  VAULT_USER = "48b1bd70-cb26-4dce-9c15-abc012ebbb90"
  VAULT_TYPE = "58b1bd70-cb26-4dce-9c15-abc012ebbb90"
  BEARER = "synthetic-preview-bearer"
  SITEKEY = "0x4AAAAAExamplePublicKey"
  WIDGET_SECRET = "0x4AAAAAExamplePrivateValue"
  VAULT_KEY = "test-service-key-not-an-agent-key"
  VAULT_PASSPHRASE = "test-service-passphrase"
  REQUEST = { "hostname" => HOSTNAME }.freeze
  PRIVATE_VALUES = [ BEARER, PAGES_BEARER, WIDGET_SECRET, VAULT_KEY, VAULT_PASSPHRASE, "untrusted provider diagnostic" ].freeze

  setup do
    install_sidecar_settings
    @credential_reads = []
    @credentials = { RESOURCE => BEARER, PAGES_RESOURCE => PAGES_BEARER }
    read = ->(record) { @credential_reads << record; @credentials.fetch(record) }
    @original_read = DurableAssistants::TurnstilePreview::Vault.instance_method(:read)
    DurableAssistants::TurnstilePreview::Vault.define_method(:read) { |record| read.call(record) }
    stub_project
    @owner = create_user(name: "Olive", email: "operator@example.com")
    @member = create_user(name: "Milo")
    @workspace = Workspace.make(name: "Preview studio", owner: @owner)
    @workspace.memberships.create!(user: @member, role: "member")
    @agent = @workspace.agents.create!(name: "Studio", user: @owner, model: Agent.models.first, instructions: "Help.")
    @conversation = create_conversation(@agent)
    @previous = Rails.application.config.x.turnstile_preview
    @settings = { enabled: true, workspace_id: @workspace.id.to_s, owner_email: @owner.email, account_id: ACCOUNT,
      hostname: HOSTNAME, project: PROJECT, project_id: PROJECT_ID, token_resource_id: RESOURCE, pages_token_resource_id: PAGES_RESOURCE,
      vault_url: "https://vault.example.test", vault_ca: "fixture trust anchor", vault_user_id: VAULT_USER,
      vault_resource_type_id: VAULT_TYPE, vault_private_key: VAULT_KEY, vault_passphrase: VAULT_PASSPHRASE }
    Rails.application.config.x.turnstile_preview = @settings
  end

  teardown do
    Rails.application.config.x.turnstile_preview = @previous
    DurableAssistants::TurnstilePreview::Vault.define_method(:read, @original_read) if @original_read
    remove_sidecar_settings
  end

  test "only the configured workspace's opted-in agent can reach the tool; custody must be explicitly enabled and separate" do
    assert_nil @conversation.tool(TOOL)
    enable_tool
    assert @conversation.reload.tool(TOOL)
    another = @owner.personal_workspace.agents.sole
    another.update!(tool_names: another.tool_names | [ TOOL ])
    assert_nil another.conversation.tool(TOOL)

    with_setting(:turnstile_preview, :enabled, false) { assert_nil @conversation.reload.tool(TOOL) }
    with_setting(:turnstile_preview, :vault_private_key, nil) { assert_nil @conversation.reload.tool(TOOL) }
    with_setting(:turnstile_preview, :vault_user_id, nil) { assert_nil @conversation.reload.tool(TOOL) }
    assert_empty @credential_reads
    assert_not_requested :any, /api\.cloudflare\.com/
  end

  test "only the release owner may approve the exact preview even with approve everything and an old Always" do
    enable_tool
    @workspace.update!(approval_policy: "everything")
    @agent.permissions.create!(tool_name: TOOL, granted_by: @owner)
    result = invoke
    assert_equal "waiting", result.fetch("status")
    call = pending_card
    assert_nil call.approval
    assert_empty call.always_choices
    assert_equal HOSTNAME, call.details.fetch("Preview hostname")
    assert_raises(Invocation::NotTheApprover) { call.approve!(by: @member) }
    assert_raises(ArgumentError) { call.approve!(by: @owner, always: "agent") }
    assert_nil call.reload.approval
    assert_empty @credential_reads
    assert_not_requested :any, /api\.cloudflare\.com/
  end

  test "the exact preview sends once, binds only the preview secret and returns only the public key and status" do
    enable_tool
    call = nil
    bind = stub_bind.to_return(bind_reply)
    create = stub_create.to_return do
      InvocationCallJob.perform_now(call.reload)
      provider_reply
    end
    log = capture_log do
      assert_equal "waiting", invoke.fetch("status")
      call = pending_card
      call.approve!(by: @owner, version: call.approval_version)
      invoke
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_equal({ "status" => "created", "sitekey" => SITEKEY }, invoke.fetch("result"))
      InvocationCallJob.perform_now(call.reload)
    end

    assert_requested create, times: 1
    assert_not_requested :delete, "#{ENDPOINT}/#{SITEKEY}"
    assert_requested bind, times: 1
    assert_equal [ RESOURCE, PAGES_RESOURCE ], @credential_reads
    assert_private(log, call.reload.attributes.to_json, invoke.to_json)
  end

  test "unsupported inputs and an approval for an old destination send nothing" do
    enable_tool
    assert invoke(REQUEST.merge("hostname" => "another.example.net"), call_id: "wrong-host")["isError"]
    assert invoke(REQUEST.merge("path" => "/anything"), call_id: "unknown-arg")["isError"]
    invoke
    call = pending_card
    old_version = call.approval_version
    call.approve!(by: @owner, version: old_version)
    sign_in_via_ajent(subject: @owner.oidc_sub, email: @owner.email, name: @owner.name)
    path = conversation_invocation_approval_path(@conversation, call)
    with_setting(:turnstile_preview, :account_id, "b" * 32) do
      invoke
      perform_enqueued_jobs(only: InvocationCallJob)
      assert_nil call.reload.approval
      assert call.awaiting_person?
      post path, params: { decision: "approve", version: old_version }
      assert_redirected_to @conversation
      assert_nil call.reload.approval
      post path, params: { decision: "approve" }
      assert_redirected_to @conversation
      assert_nil call.reload.approval
      get approval_path(call)
      version = Invocation::Card.new(call).version
      assert_select "##{call.dom_target} input[name=version][value='#{version}']", count: 1
      post path, params: { decision: "approve", version: version }
      assert_redirected_to @conversation
      assert call.reload.approved?
    end
    assert_empty @credential_reads
    assert_not_requested :any, /api\.cloudflare\.com/
  end

  test "HTTP and malformed success responses never surface the provider body, bearer or new secret" do
    enable_tool
    fault = { secret: WIDGET_SECRET, echoed: BEARER, detail: "untrusted provider diagnostic" }.to_json
    stub_create.to_return(status: 403, body: fault).then.to_return(status: 201, body: "{incomplete #{fault}")
    log = capture_log do
      denied = approve_and_run(call_id: "provider-denied")
      uncertain = approve_and_run(call_id: "invalid-response")
      assert_match(/refused.*403/, denied.error)
      assert_match(/check.*before trying again/i, uncertain.error)
      assert_private(denied.attributes.to_json, uncertain.attributes.to_json, denied.outcome.to_json, uncertain.outcome.to_json)
    end
    assert_private(log)
    assert_not_requested :patch, PAGES
  end

  test "a confirmed widget with an unusable secret is revoked without writing the binding" do
    enable_tool
    stub_create.to_return(status: 201, body: { success: true, result: { sitekey: SITEKEY, secret: BEARER, domains: [ HOSTNAME ] } }.to_json)
    cleanup = stub_revoke.to_return(status: 200, body: { success: true }.to_json)
    log = capture_log do
      call = approve_and_run
      assert_match(/revoked/, call.error)
      assert_private(call.outcome.to_json, call.attributes.to_json)
    end
    assert_requested cleanup, times: 1
    assert_not_requested :patch, PAGES
    assert_private(log)
  end

  test "a confirmed bind rejection deletes only the just-created widget" do
    enable_tool
    bind = stub_bind.to_return(status: 403, body: { success: false, errors: [ { message: WIDGET_SECRET } ] }.to_json)
    stub_create.to_return(provider_reply)
    cleanup = stub_revoke.to_return(status: 200, body: { success: true, result: { sitekey: SITEKEY, secret: WIDGET_SECRET } }.to_json)
    log = capture_log do
      call = approve_and_run
      assert_match(/revoked.*check Pages/i, call.error)
      assert_private(call.outcome.to_json, call.attributes.to_json)
    end
    assert_requested cleanup, times: 1
    assert_requested bind, times: 1
    assert_private(log)
  end

  test "uncertain cleanup reports only the public key and never retries the create or the revoke" do
    enable_tool
    stub_bind.to_return(status: 403, body: { success: false }.to_json)
    create = stub_create.to_return(provider_reply)
    cleanup = stub_revoke.to_raise(Net::ReadTimeout.new("untrusted provider diagnostic #{WIDGET_SECRET}"))
    log = capture_log do
      call = approve_and_run
      assert_includes call.error, SITEKEY
      assert_match(/could not confirm.*check.*before trying again/i, call.error)
      assert_private(call.outcome.to_json, call.attributes.to_json)
      InvocationCallJob.perform_now(call.reload)
      invoke
    end
    assert_requested create, times: 1
    assert_requested cleanup, times: 1
    assert_private(log)
  end

  test "an uncertain Pages write is not replayed and does not delete a potentially bound widget" do
    enable_tool
    create = stub_create.to_return(provider_reply)
    bind = stub_bind.to_raise(Net::ReadTimeout.new("untrusted provider diagnostic #{WIDGET_SECRET}"))
    call = approve_and_run
    assert_includes call.error, SITEKEY
    assert_private(call.attributes.to_json, call.outcome.to_json)
    InvocationCallJob.perform_now(call.reload)
    invoke
    assert_requested bind, times: 1
    assert_requested create, times: 1
    assert_not_requested :delete, "#{ENDPOINT}/#{SITEKEY}"
  end

  test "a mismatched Pages project or occupied preview binding stops before creating a widget" do
    enable_tool
    stub_project(id: "wrong-project")
    approve_and_run(call_id: "wrong-project")
    stub_project(env_vars: { "TURNSTILE_SECRET" => { type: "secret_text" } })
    approve_and_run(call_id: "occupied")
    assert_not_requested :post, ENDPOINT
    assert_not_requested :patch, PAGES
  end

  test "a changed project requires a fresh exact approval" do
    enable_tool
    invoke
    call = pending_card
    old_version = call.approval_version
    call.approve!(by: @owner, version: old_version)
    with_setting(:turnstile_preview, :project, "another-preview") do
      invoke
      perform_enqueued_jobs(only: InvocationCallJob)
      assert call.reload.awaiting_person?
      assert_raises(Invocation::StaleApproval) { call.approve!(by: @owner, version: old_version) }
    end
    assert_empty @credential_reads
    assert_not_requested :any, /api\.cloudflare\.com/
  end

  test "credentials for the two provider capabilities must be distinct before dispatch" do
    enable_tool
    @credentials[PAGES_RESOURCE] = BEARER
    call = approve_and_run
    assert_match(/separate Turnstile and Pages credentials/, call.error)
    assert_not_requested :any, /api\.cloudflare\.com/
    assert_private(call.attributes.to_json, call.outcome.to_json)
  end

  private
    def enable_tool = @agent.update!(tool_names: @agent.tool_names | [ TOOL ])

    def invoke(arguments = REQUEST, call_id: "preview")
      post "/agent/invocations", params: invocation_payload(@conversation, tool: TOOL, arguments: arguments, call_id: call_id), headers: rails_bearer, as: :json
      assert_response :success
      response.parsed_body
    end

    def pending_card(call_id: "preview")
      perform_enqueued_jobs(only: InvocationPreviewJob)
      @conversation.invocations.find_by!(call_id: call_id).tap { assert it.awaiting_person? }
    end

    def approve_and_run(call_id: "preview")
      assert_equal "waiting", invoke(call_id: call_id).fetch("status")
      call = pending_card(call_id: call_id)
      call.approve!(by: @owner, version: call.approval_version)
      invoke(call_id: call_id)
      perform_enqueued_jobs(only: InvocationCallJob)
      assert call.reload.failed?
      call
    end

    def stub_project(id: PROJECT_ID, env_vars: { "UNCHANGED" => { type: "secret_text" } })
      stub_request(:get, PAGES).with(headers: { "Authorization" => "Bearer #{PAGES_BEARER}" }).to_return(
        status: 200, body: { success: true, result: { id: id, name: PROJECT, deployment_configs: {
          preview: { env_vars: env_vars }, production: { env_vars: { "TURNSTILE_SECRET" => { type: "secret_text" } } }
        } } }.to_json)
    end

    def stub_bind
      stub_request(:patch, PAGES).with(headers: { "Authorization" => "Bearer #{PAGES_BEARER}", "Content-Type" => "application/json" },
        body: { "deployment_configs" => { "preview" => { "env_vars" => {
          "TURNSTILE_SECRET" => { "type" => "secret_text", "value" => WIDGET_SECRET }
        } } } }.to_json)
    end

    def bind_reply
      { status: 200, body: { success: true, result: { id: PROJECT_ID, name: PROJECT, deployment_configs: {
        preview: { env_vars: { "TURNSTILE_SECRET" => { type: "secret_text", value: WIDGET_SECRET } } }
      } } }.to_json }
    end

    def stub_create
      stub_request(:post, ENDPOINT).with(headers: { "Authorization" => "Bearer #{BEARER}", "Content-Type" => "application/json" }) do |request|
        body = JSON.parse(request.body)
        body.keys.sort == %w[ domains mode name ] && body.fetch("domains") == [ HOSTNAME ] && body.fetch("mode") == "managed"
      end
    end

    def stub_revoke
      stub_request(:delete, "#{ENDPOINT}/#{SITEKEY}").with(headers: { "Authorization" => "Bearer #{BEARER}" })
    end

    def provider_reply = { status: 201, body: { success: true, result: { sitekey: SITEKEY, secret: WIDGET_SECRET,
      domains: [ HOSTNAME ], other: "untrusted provider diagnostic" } }.to_json }

    def assert_private(*outputs)
      outputs.each { |output| PRIVATE_VALUES.each { assert_not_includes output, it } }
    end

    def capture_log
      output = StringIO.new
      previous = [ Rails.logger, ActiveJob::Base.logger, ActionController::Base.logger ]
      Rails.logger = ActiveJob::Base.logger = ActionController::Base.logger = ActiveSupport::BroadcastLogger.new(previous.first, ActiveSupport::Logger.new(output))
      yield
      output.string
    ensure
      Rails.logger, ActiveJob::Base.logger, ActionController::Base.logger = previous
    end
end
