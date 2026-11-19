require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# A workspace's Usage page (docs/billing.md): what its own agents' calls used
# this month and last, by agent, by model and by who paid, for its members
# alone; and its payer, which only its owner chooses, and only among the
# install and workspaces they own.
class WorkspaceUsageTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  setup do
    install_sidecar_settings
    travel_to Time.utc(2026, 11, 17, 12)
    @alice = create_user(name: "Alice")
    @bob = create_user(name: "Bob")
    @carol = create_user(name: "Carol")
    @acorn = Workspace.create!(name: "Acorn")
    @acorn.memberships.create!(user: @alice, role: "owner")
    @acorn.memberships.create!(user: @bob, role: "member")
    @birch = Workspace.create!(name: "Birch")
    @birch.memberships.create!(user: @alice, role: "owner")
    @cedar = Workspace.create!(name: "Cedar")
    @cedar.memberships.create!(user: @carol, role: "owner")
    @ada = @alice.start_agent("Ada", workspace: @acorn)
    @bea = @alice.start_agent("Bea", workspace: @birch)
    @cy = @carol.start_agent("Cy", workspace: @cedar)
  end
  teardown { remove_sidecar_settings }

  test "a member sees this month's and last month's usage of the workspace's own agents, by agent, model and payer" do
    use @ada, model: "anthropic/claude-opus-5-5", input: 1_000, output: 200, cost: 0.12, payer: @birch, at: 2.days.ago
    use @ada, model: "anthropic/claude-opus-5-5", input: 500, output: 100, at: 1.day.ago
    use @ada, tool: "web_search", input: 40, output: 5, at: 1.hour.ago
    use @ada, model: "anthropic/claude-haiku-5-5", input: 70, output: 7, at: 1.month.ago
    use @bea, model: "anthropic/claude-opus-5-5", input: 9_999, output: 9_999, at: 1.hour.ago
    use @cy, model: "anthropic/claude-opus-5-5", input: 8_888, output: 8_888, payer: @acorn, at: 1.hour.ago

    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_usage_path(@acorn)
    assert_response :success

    assert_select "section#this_month" do
      assert_select "li", text: /Ada.*1,540 in.*305 out/m
      assert_select "li", text: /Claude Opus 5\.5.*1,500 in.*300 out/m
      assert_select "li", text: /Web search.*40 in.*5 out/m
      assert_select "li", text: /Birch.*1,000 in.*200 out.*about \$0\.12/m
      assert_select "li", text: /The install.*540 in.*105 out/m
    end
    assert_select "section#last_month" do
      assert_select "li", text: /Claude Haiku 5\.5.*70 in.*7 out/m
    end
    assert_select "p", text: /Billed to the install/
    assert_not_includes response.body, "Bea", "another workspace's agent, even one Acorn's owner owns"
    assert_not_includes response.body, "Cy", "nor one Acorn pays for"
    assert_not_includes response.body, "9,999"
    assert_not_includes response.body, "8,888"
  end

  test "a workspace with nothing used says so" do
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_usage_path(@acorn)
    assert_select "section#this_month p", text: /Nothing used/
  end

  test "someone outside the workspace finds no Usage page" do
    sign_in_via_ajent(subject: "sub-carol", email: "carol@example.com", name: "Carol")
    get workspace_usage_path(@acorn)
    assert_response :not_found
  end

  test "the owner bills the workspace to another they own, then to itself, then back to the install" do
    sign_in_via_ajent(subject: "sub-alice", email: "alice@example.com", name: "Alice")
    get workspace_usage_path(@acorn)
    assert_select "select[name='workspace[payer_id]'] option", count: 4 # the install, Acorn, Birch, and her personal workspace
    assert_select "select[name='workspace[payer_id]'] option", text: "Cedar", count: 0
    assert_select "select[name='workspace[payer_id]'] option", text: "Alice (personal)"

    patch workspace_payer_path(@acorn), params: { workspace: { payer_id: @birch.id } }
    assert_redirected_to workspace_usage_path(@acorn)
    assert_equal @birch, @acorn.reload.payer
    follow_redirect!
    assert_select "select[name='workspace[payer_id]'] option[selected]", text: "Birch"

    patch workspace_payer_path(@acorn), params: { workspace: { payer_id: @acorn.id } }
    assert_equal @acorn, @acorn.reload.payer

    patch workspace_payer_path(@acorn), params: { workspace: { payer_id: "" } }
    assert_nil @acorn.reload.payer
  end

  test "nobody bills a workspace to one they do not own, and a member does not choose" do
    sign_in_via_ajent(subject: "sub-alice", email: "alice@example.com", name: "Alice")
    patch workspace_payer_path(@acorn), params: { workspace: { payer_id: @cedar.id } }
    assert_response :not_found
    assert_nil @acorn.reload.payer

    reset!
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_usage_path(@acorn)
    assert_select "select[name='workspace[payer_id]']", count: 0
    patch workspace_payer_path(@acorn), params: { workspace: { payer_id: @bob.personal_workspace.id } }
    assert_response :not_found
    assert_nil @acorn.reload.payer
  end

  test "the shared workspace's page says who pays and leads to its Usage" do
    @acorn.update!(payer: @birch)
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_path(@acorn)
    assert_select "#billing", text: /Billed to Birch/
    assert_select "#billing a[href='#{workspace_usage_path(@acorn)}']"
  end

  private
    def use(agent, payer: nil, model: nil, tool: nil, input: 0, output: 0, cost: nil, at:)
      agent.workspace.model_usages.create!(agent: agent, agent_name: agent.name, payer: payer, model: model, tool: tool,
        input: input, output: output, total_tokens: input + output, cost: cost, created_at: at)
    end
end
