require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A skill the agent loads shows on its turn by name, so a person sees which
# one shaped the answer without opening the call. Other tools keep "Ran …".
class SkillMarkerTest < ActionView::TestCase
  include AgentTestHelper

  setup do
    @agent = create_user(name: "Alice").agents.sole
    @conversation = create_conversation(@agent)
  end

  test "a read_skill call is marked Used skill with its name; another tool still reads Ran" do
    @agent.skills.create!(name: "trip-planning", description: "Plan a trip.", body: "Ask for dates first.")
    assert_equal "Used skill: trip-planning", title_of(ledger("read_skill", { "name" => "trip-planning" }))
    assert_equal "Ran list notes", title_of(ledger("list_notes", {}))
  end

  private
    # Through the ledger, as the sidecar sends a call: read_skill and list_notes run without asking.
    def ledger(tool, arguments)
      payload = invocation_payload(@conversation, tool: tool, arguments: arguments, call_id: "call-#{tool}")
      Invocation.receive(@conversation, task_id: payload[:taskId], call_id: "call-#{tool}", tool: tool, arguments: arguments, digest: payload[:digest])
      invocation = @conversation.invocations.find_by!(call_id: "call-#{tool}")
      assert invocation.succeeded?, invocation.state
      render partial: "invocations/invocation", locals: { invocation: invocation }
    end

    def title_of(html) = Nokogiri::HTML5.fragment(html).at(".ui-trace__title").text.squish
end
