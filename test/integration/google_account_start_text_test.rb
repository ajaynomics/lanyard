require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class GoogleAccountStartTextTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  test "only the signed-in issuer can text the same outside link to their workspace number" do
    person = create_user
    owner = create_user(name: "Workspace Owner", email: "owner@example.com")
    workspace = Workspace.create!(name: "Text link workspace", voipms_vault_entry: "Synthetic carrier account")
    workspace.memberships.create!(user: owner, role: :owner, phone_number: "4165550101")
    membership = workspace.memberships.create!(user: person, role: :member, phone_number: "4165550102")
    person.personal_workspace.memberships.find_by!(user: person).update!(phone_number: "4165550103")
    agent = person.start_agent("Sender", workspace: workspace)
    sender = "4165550104"
    agent.update!(phone_number: sender)
    conversation = agent.conversation
    connector = workspace.mcp_servers.create!(user: person, name: "outside_gmail", conversation: conversation, enabled: false,
      url: "https://gmailmcp.googleapis.com/mcp/v1", oauth_scope: "https://www.googleapis.com/auth/gmail.readonly",
      oauth_client: { "client_id" => "synthetic-client", "client_secret" => "synthetic-client-secret" })
    path = connector_google_account_start_path(connector)
    expected = "mailbox@example.com"
    text = { expected_email: expected, delivery: "text" }
    carrier = DurableAssistants::Voipms
    original = carrier.method(:send_text)
    sends = []
    failure = nil
    carrier.define_singleton_method(:send_text) do |**fields|
      sends << fields
      raise failure if failure
      123
    end

    sign_in_via_ajent(subject: person.oidc_sub, email: person.email, name: person.name)
    open_session.post path, params: text
    assert_empty sends

    post "#{path}?delivery=text", params: { expected_email: expected }
    assert_response :created
    assert_empty sends

    post path, params: text.merge(expected_email: "not-an-email")
    assert_response :unprocessable_content
    assert_empty sends

    post path, params: text
    assert_response :created
    assert_equal 1, sends.size
    link = css_select("#google-account-start-link").sole["value"]
    uri = URI(link)
    assert_equal "http://localhost/google_account_start", uri.to_s.split("#").first
    assert_match GoogleAccountStart::TOKEN, uri.fragment
    attempt = connector.google_account_starts.sole
    assert_equal GoogleAccountStart.digest("start", uri.fragment), attempt.token_digest
    assert_equal person, attempt.issued_by
    assert attempt.matches?(expected)
    assert_equal({ from: sender, to: membership.phone_number, body: link, account: workspace.voipms_account(as: agent) }, sends.sole)
    assert_select "p", "Text sent to your number on file."
    assert_equal "no-store", response.headers["Cache-Control"]

    get conversation_connectors_path(conversation)
    assert_select "form[action='#{path}'][method='post'] button[name=delivery][value=text]", "Text me this link"

    other = person.start_agent("Other sender", workspace: workspace)
    membership.update!(sole_contact: other)
    post path, params: text
    assert_response :unprocessable_content
    membership.update!(sole_contact: nil, phone_number: "0000000000")
    post path, params: text
    assert_response :unprocessable_content
    membership.update!(phone_number: "4165550102")
    workspace.update!(voipms_vault_entry: nil)
    post path, params: text
    assert_response :unprocessable_content
    assert_equal 1, sends.size

    workspace.update!(voipms_vault_entry: "Synthetic carrier account")
    failure = carrier::Error.new("synthetic private carrier detail")
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    previous = [ Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger ]
    Rails.logger = ActionController::Base.logger = ActiveRecord::Base.logger = logger
    post path, params: text
    assert_response :service_unavailable
    assert_select "p", "We couldn't confirm the text was sent. Check your phone before trying again."
    assert_not_includes response.body, failure.message
    assert_equal 2, sends.size
    [ sender, membership.phone_number, expected, sends.last.fetch(:body), failure.message ].each do |private_value|
      assert_not_includes output.string, private_value
    end
  ensure
    carrier.define_singleton_method(:send_text, original) if original
    Rails.logger, ActionController::Base.logger, ActiveRecord::Base.logger = previous if previous
  end
end
