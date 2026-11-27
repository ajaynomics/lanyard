require "test_helper"
require_relative "../../test_helpers/agent_test_helper"
require_relative "../../test_helpers/concourse_test_helper"

# Under "Ask before what reaches other people" a send that stays inside asks
# no one: a Concourse send on a network the install names inside. Everything
# else that reaches people still asks, Campfire included.
class Tool::InsideSendsTest < ActiveSupport::TestCase
  include AgentTestHelper
  include ConcourseTestHelper

  setup do
    install_sidecar_settings
    @agent = create_user.agents.sole
    @conversation = create_conversation(@agent)
    create_concourse_agent(@agent)
    create_second_network(@agent)
    @others = Workspace::ApprovalPolicy.new("others")
  end

  teardown { remove_sidecar_settings }

  test "a Concourse send on a network the install names inside doesn't ask; on any other network it does" do
    with_setting(:app, :inside_concourse_networks, [ "acme" ]) do
      assert @others.allows?(send_on("acme")), "inside"
      assert_not @others.allows?(send_on("example")), "another network"
      assert_not @others.allows?(send_on(nil)), "no network named, on an agent with two"
    end
    assert_not @others.allows?(send_on("acme")), "without the setting, every send asks"
  end

  test "a bridge is never inside" do
    @agent.workspace.update!(concourse_home: "example")
    with_setting(:app, :inside_concourse_networks, [ "acme", "example" ]) do
      assert_not @others.allows?(send_on("acme")), "acme is a bridge from example"
      assert @others.allows?(send_on("example"))
    end
  end

  test "a Campfire post still asks, even into a room that has written to the workspace" do
    @agent.workspace.campfire_rooms.create!(room_id: 5)
    assert_not @others.allows?(tool(Tool::CampfireSay, "room" => 5, "text" => "Done."))
  end

  test "the other sends still ask, and approving everything is unchanged" do
    with_setting(:app, :inside_concourse_networks, [ "acme" ]) do
      assert_not @others.allows?(tool(Tool::SendText, "to" => "4165550199", "body" => "Hi."))
      assert_not @others.allows?(tool(Tool::SendEmail, "to" => [ "robin@example.com" ], "subject" => "Hi", "body" => "Hi."))
      assert Workspace::ApprovalPolicy.new("everything").allows?(send_on("example"))
    end
  end

  private
    def send_on(network)
      tool(Tool::ConcourseSend, { "to" => "acme/travel", "text" => "Find a train.", "network" => network }.compact)
    end

    def tool(klass, arguments)
      @calls = @calls.to_i + 1
      klass.new(@conversation.invocations.create!(task_id: "7", call_id: "c#{@calls}", tool_name: klass.tool_name, arguments: arguments, digest: "d"))
    end
end
