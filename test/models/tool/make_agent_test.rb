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
    assert_not_includes @conversation.definition[:tools].pluck(:name), "make_agent"
    @agent.update!(tool_names: @agent.tool_names + [ "make_agent" ])
    assert_includes @conversation.reload.definition[:tools].pluck(:name), "make_agent"
  end

  test "the person is asked, in words, exactly what will be made, never Always, and allowing it makes the agent with its Campfire bot" do
    @agent.update!(tool_names: @agent.tool_names + [ "make_agent" ])
    arguments = { "name" => "Jordan Reyes", "address" => "jordan", "purpose" => "Maya's work: her calendar and mail." }

    with_install do
      assert_equal "waiting", receive(arguments, call_id: "c1")[:status]
      assert_not Agent.exists?(name: "Jordan Reyes") # tenancy-ok: nothing is made before the person answers

      card = Nokogiri::HTML5.fragment(ApplicationController.render(partial: "invocations/invocation",
        locals: { invocation: @conversation.invocations.find_by!(call_id: "c1") }))
      assert_equal "Make Jordan Reyes at jordan@agents.example, a permanent agent with its own computer and Campfire bot?",
        card.at_css(".approval .ui-card__title").text.strip
      assert_empty card.css(".approval button").map(&:text).grep(/Always/)

      @conversation.invocations.find_by!(call_id: "c1").approve!(by: @person)
      result = nil
      assert_enqueued_with(job: CampfireBotJob) { result = receive(arguments, call_id: "c1")[:result] }
      jordan = @person.agents.find_by!(name: "Jordan Reyes")
      assert_equal({ made: "Jordan Reyes", address: "jordan@agents.example", thread: conversation_path(jordan.conversation) }, result)
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

  private
    def with_install(&)
      with_setting(:mail, :domain, "agents.example") do
        with_setting(:mail, :smtp_address, "smtp.agents.example") do
          with_setting(:campfire, :url, "http://example-campfire") do
            with_setting(:campfire, :admin_email, "admin@example.com") do
              with_setting(:campfire, :admin_password, "correct-horse", &)
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
