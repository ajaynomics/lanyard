require "test_helper"
require_relative "../../test_helpers/agent_test_helper"

class Agent::ReportingTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup do
    @owner = create_user
    @workspace = @owner.personal_workspace
    @top, @middle, @leaf, @other = %w[ Aster Rill Pip Sable ].map { @owner.start_agent(it) }
  end

  test "one workspace and three levels, counting the entire branch" do
    @middle.update!(parent_id: @top.id)
    @leaf.update!(parent_id: @middle.id)
    outside = Workspace.make(name: "Other", owner: @owner)
    stranger = @owner.start_agent("Stranger", workspace: outside)

    assert_equal @top, @middle.manager
    assert_equal [ @leaf ], @middle.reports.to_a
    [ [ @top, @top ], [ @top, @leaf ], [ @other, @leaf ], [ @top, @other ], [ @leaf, stranger ] ].each do |child, parent|
      assert_not child.update(parent_id: parent.id), "#{child} cannot report to #{parent}"
      child.reload
    end
    assert_not @leaf.update(parent_id: 999_999)
    assert @middle.update(parent_id: @other.id)
    assert_equal @middle, @leaf.reload.manager
  end

  test "archive keeps links but an archived agent cannot become a new manager" do
    @middle.update!(parent_id: @top.id)
    @top.conversation.archive
    assert_equal @top, @middle.reload.manager
    assert_not @other.update(parent_id: @top.id)
    @top.conversation.unarchive
    assert @other.update(parent_id: @top.id)
  end

  test "deleting or leaving a workspace promotes only direct reports, with their branches" do
    @middle.update!(parent_id: @top.id)
    @leaf.update!(parent_id: @middle.id)
    @top.destroy!
    assert_nil @middle.reload.parent_id
    assert_equal @middle, @leaf.reload.manager

    @middle.update!(parent_id: @other.id)
    destination = Workspace.make(name: "Juniper", owner: @owner)
    assert @middle.move_to(destination, by: @owner)
    assert_equal destination, @middle.reload.workspace
    assert_nil @middle.parent_id
    assert_equal @other, @leaf.reload.manager
    assert_equal @workspace, @leaf.workspace
  end

  test "a rollback's missing or foreign parent resolves as no manager" do
    outside = Workspace.make(name: "Other", owner: @owner)
    stranger = @owner.start_agent("Stranger", workspace: outside)
    [ 999_999, stranger.id ].each do |old_id|
      @middle.update_columns(parent_id: old_id)
      assert_nil @middle.manager
      assert_includes Workspace::Group.of(@owner).find { it.workspace == @workspace }.tree.roots.map(&:agent), @middle
    end
    assert_empty stranger.reports
  end

  test "the next definition names only immediate reporting lines and a usable home route" do
    @workspace.update!(concourse_home: "juniper")
    before = @middle.definition([])
    @middle.update!(parent_id: @top.id)
    @leaf.update!(parent_id: @middle.id)
    @other.update!(parent_id: @top.id)
    [ @top, @middle, @leaf ].each { identity(it, "bridge", bridge_approved_at: Time.current) }
    [ @top, @middle ].each { identity(it, "juniper") }

    after = @middle.definition([])
    assert_not_equal before[:digest], after[:digest]
    assert_match(/Manager: Aster.*juniper\/aster.*network juniper/, after[:instructions])
    assert_match(/Direct report: Pip.*no clear Concourse route/i, after[:instructions])
    assert_not_includes after[:instructions], "Sable"
    assert_not_includes after[:instructions], "bridge/pip"
    assert_includes after[:instructions], "concourse_reply"
    assert_equal before[:tools], after[:tools]
    assert_not_includes @top.definition([])[:instructions], "Pip"
  end

  test "without a home reporting uses only a single shared connected network" do
    @middle.update!(parent_id: @top.id)
    identity(@top, "juniper")
    identity(@middle, "juniper")
    identity(@top, "cedar")
    identity(@middle, "cedar", status: "disconnected")

    assert_match(/Manager: Aster.*juniper\/aster/, @middle.definition([])[:instructions])
    @middle.concourse_agents.find_by!(organization: "cedar").update!(status: "admitted")
    assert_match(/Manager: Aster.*no clear Concourse route/i, @middle.definition([])[:instructions])
  end

  private
    def identity(agent, network, **attributes)
      agent.concourse_agents.create!({ organization: network, handle: "#{network}/#{agent.name.downcase}",
        client_id: "test-#{agent.id}-#{network}", client_secret: "test-secret", status: "admitted", checked_at: Time.current }.merge(attributes))
    end
end
