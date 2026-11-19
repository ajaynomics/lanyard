require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

# A chief of staff makes the agents under her: off unless switched on, asked
# every time with exactly what will be made, and made as New agent makes one.
class Tool::MakeAgentTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActiveJob::TestHelper

  setup do
    sign_in_via_ajent
    @person = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads the person it signed in
    @agent = @person.agents.sole
    @conversation = create_conversation(@agent)
  end

  test "an agent has it only when switched on" do
    assert_nil @conversation.tool("make_agent")
    @agent.update!(tool_names: @agent.tool_names + [ "make_agent" ])
    assert @conversation.reload.tool("make_agent")
  end

  test "the person is asked, in words, exactly what will be made, never Always, and allowing it makes the agent with its Campfire bot" do
    @agent.update!(tool_names: @agent.tool_names + [ "make_agent" ])
    arguments = { "name" => "Jordan Reyes", "title" => "Acme Assistant", "address" => "jordan", "purpose" => "Maya's work: her calendar and mail." }

    with_install do
      assert_equal "waiting", receive(arguments, call_id: "c1")[:status]
      assert_not Agent.exists?(name: "Jordan Reyes") # tenancy-ok: nothing is made before the person answers

      card = Nokogiri::HTML5.fragment(ApplicationController.render(partial: "invocations/invocation",
        locals: { invocation: @conversation.invocations.find_by!(call_id: "c1") }))
      assert_equal "Make Jordan Reyes (Acme Assistant) at jordan@agents.example, a permanent agent with its own computer and Campfire bot?",
        card.at_css(".approval .ui-card__title").text.strip
      assert_empty card.css(".approval button").map(&:text).grep(/Always/)

      @conversation.invocations.find_by!(call_id: "c1").approve!(by: @person)
      result = nil
      assert_enqueued_with(job: CampfireBotJob) { result = receive(arguments, call_id: "c1")[:result] }
      jordan = @person.agents.find_by!(name: "Jordan Reyes")
      assert_equal({ made: "Jordan Reyes", title: "Acme Assistant", address: "jordan@agents.example", thread: conversation_path(jordan.conversation) }, result,
        "nothing offers Concourse: only an agent the person asks to join goes there")
      assert_match(/## Your purpose\n\nMaya's work/, jordan.instructions)
      assert_not_includes jordan.tool_names, "make_agent"
    end
  end

  test "a taken address is refused, and nothing is made" do
    @agent.update!(tool_names: @agent.tool_names + [ "make_agent" ])
    arguments = { "name" => "Casey Reyes", "address" => @agent.email_name }
    receive(arguments, call_id: "c2")
    @conversation.invocations.find_by!(call_id: "c2").approve!(by: @person)

    assert_no_difference -> { @person.agents.count } do
      assert_match(/Email name is another agent's/, receive(arguments, call_id: "c2").to_s)
    end
  end

  test "an agent in a shared workspace makes the new agent there, as New agent does in the workspace a person works in" do
    team = Workspace.create!(name: "Team").tap { it.memberships.create!(user: @person, role: "owner") }
    @agent = @person.start_agent("Chief", workspace: team)
    @agent.update!(tool_names: @agent.tool_names + [ "make_agent" ])
    @conversation = create_conversation(@agent, durable_id: "13")
    receive({ "name" => "Casey Reyes" }, call_id: "c3")
    @conversation.invocations.find_by!(call_id: "c3").approve!(by: @person)
    receive({ "name" => "Casey Reyes" }, call_id: "c3")

    assert_equal team, @person.agents.find_by!(name: "Casey Reyes").workspace
  end

  private
    def with_install(&)
      with_setting(:mail, :domain, "agents.example") do
        with_setting(:mail, :smtp_address, "smtp.agents.example") do
          with_setting(:campfire, :url, "http://example-campfire") do
            with_setting(:campfire, :admin_email, "admin@example.com") do
              with_setting(:campfire, :admin_password, "correct-horse") do
                with_setting(:concourse, :origin, "https://concourse.example") do
                  with_setting(:concourse, :token_url, "https://id.example/oauth/token", &)
                end
              end
            end
          end
        end
      end
    end

    def receive(arguments, call_id:)
      payload = invocation_payload(@conversation, tool: "make_agent", arguments: arguments, call_id: call_id)
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "make_agent",
        arguments: arguments, digest: payload[:digest]).deep_symbolize_keys
    end
end
