require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# The owner of an agent's workspace changes its address, on its General page.
class Agents::EmailAddressesControllerTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    sign_in_via_ajent
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    @agent = @owner.agents.sole
  end

  test "the owner changes its address, which must be free and well formed" do
    with_mail do
      get agent_path(@agent)
      assert_select "#agent_identity form[action=?] input[name='agent[email_name]'][value=assistant]", agent_email_address_path(@agent)
      assert_select "#agent_email_address button[type=submit][data-turbo-confirm*=?]", "assistant@agents.example stops taking new mail"

      patch agent_email_address_path(@agent), params: { agent: { email_name: "Avery@" } }
      assert_response :see_other
      assert_equal "avery@agents.example", @agent.reload.email_address

      @owner.start_agent("Travel")
      patch agent_email_address_path(@agent), params: { agent: { email_name: "travel" } }
      assert_response :unprocessable_entity
      assert_select "#agent_email_address .field__error", text: "Email address is another agent's", count: 1
      patch agent_email_address_path(@agent), params: { agent: { email_name: "two words" } }
      assert_select "#agent_email_address input[name='agent[email_name]'][value='two words'][aria-invalid=true]"
      assert_select "#agent_email_address .field__error", /may have only lowercase letters/
      assert_select "#delete_agent", text: /avery@agents\.example/
      assert_equal "avery", @agent.reload.email_name
    end
  end

  test "another member of a shared workspace sees the address but can't change it" do
    shared = Workspace.create!(name: "Household")
    shared.memberships.create!(user: @owner, role: "owner")
    agent = shared.agents.create!(user: @owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
    shared.memberships.create!(user: create_user(name: "Bob"), role: "member")
    reset!
    sign_in_via_ajent(name: "Bob", subject: "sub-bob", email: "bob@example.com")
    get workspace_path(shared)

    with_mail do
      get agent_path(agent)
      assert_select "#agent_identity input[name='agent[email_name]']", count: 0
      patch agent_email_address_path(agent), params: { agent: { email_name: "bobs" } }
      assert_response :not_found
      assert_equal "shared", agent.reload.email_name
    end
  end

  private
    def with_mail(&block)
      with_setting(:mail, :domain, "agents.example") { with_setting(:mail, :smtp_address, "smtp.agents.example", &block) }
    end
end
