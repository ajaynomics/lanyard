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

  test "pilot usage shows settled, held and threshold amounts only for this workspace" do
    voice = @ada.pilot_budget(:voice)
    voice.reserve("settled", 2_500)
    voice.settle("settled", 2_500)
    voice.reserve("held", 300)
    @bea.pilot_budget(:computer).reserve("elsewhere", 1_900)

    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_usage_path(@acorn)

    assert_response :success
    assert_select "section#pilot_usage" do
      assert_select "li", count: 1, text: /Ada.*Voice: \$25\.00 used of \$50\.00.*\$3\.00 reserved.*\$22\.00 left.*50% used/m
    end
  end

  test "a workspace with nothing used says so" do
    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_usage_path(@acorn)
    assert_select "section#this_month p", text: /Nothing used/
    assert_select "section#pilot_usage", count: 0
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

  test "By file sums each file's usage, its estimated cost first, and what was filed under nothing as untagged" do
    use @ada, model: "anthropic/claude-opus-5-5", input: 1_000, output: 200, cost: 0.12, file: "EXAMPLE-FILE-A", at: 2.days.ago
    use @ada, tool: "web_search", input: 40, output: 5, cost: 0.01, file: "EXAMPLE-FILE-A", at: 1.day.ago
    use @ada, model: "anthropic/claude-opus-5-5", input: 300, output: 30, cost: 0.03, file: "EXAMPLE-FILE-B", at: 1.day.ago
    use @ada, model: "anthropic/claude-opus-5-5", input: 70, output: 7, at: 1.hour.ago

    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_usage_path(@acorn)

    assert_select "section#this_month table#this_month_by_file" do
      assert_equal [ "File", "Estimated cost", "Total tokens", "Input", "Output" ], css_select("thead th").map { it.text.strip }
      rows = css_select("tbody tr").map { |row| row.css("th, td").map { it.text.strip } }
      assert_equal [ [ "EXAMPLE-FILE-A", "$0.13", "1,245", "1,040", "205" ], [ "EXAMPLE-FILE-B", "$0.03", "330", "300", "30" ],
        [ "untagged", "—", "77", "70", "7" ] ], rows
    end
  end

  test "from and to dates narrow every table to those days, and without them the page shows this month and last" do
    use @ada, model: "anthropic/claude-opus-5-5", input: 111, output: 1, file: "EXAMPLE-FILE-A", at: Time.utc(2026, 10, 30, 12)
    use @ada, model: "anthropic/claude-opus-5-5", input: 222, output: 2, file: "EXAMPLE-FILE-B", at: Time.utc(2026, 11, 2, 12)
    use @ada, model: "anthropic/claude-opus-5-5", input: 444, output: 4, at: Time.utc(2026, 11, 16, 12)

    sign_in_via_ajent(subject: "sub-bob", email: "bob@example.com", name: "Bob")
    get workspace_usage_path(@acorn, from: "2026-10-30", to: "2026-11-02")
    assert_response :success

    assert_select "section#this_month", count: 0
    assert_select "section#last_month", count: 0
    assert_select "section#chosen_dates" do
      assert_select "h2", text: /30 October 2026 to 2 November 2026/
      assert_select "li", text: /In all.*333 in.*3 out/m
      assert_select "li", text: /Ada.*333 in/m
      assert_select "li", text: /Claude Opus 5\.5.*333 in/m
      assert_select "li", text: /The install.*333 in/m
      assert_select "tbody th", text: "EXAMPLE-FILE-A"
      assert_select "tbody th", text: "EXAMPLE-FILE-B"
      assert_select "tbody th", text: "untagged", count: 0
    end
    assert_select "section#chosen_dates", text: /\b444\b/, count: 0
    assert_select "form[method=get] input[type=date][name=from][value='2026-10-30']"
    assert_select "form[method=get] input[type=date][name=to][value='2026-11-02']"

    get workspace_usage_path(@acorn, from: "2026-11-10")
    assert_select "section#chosen_dates h2", text: /From 10 November 2026/
    assert_select "section#chosen_dates tbody th", text: "untagged"
    assert_not_includes response.body, "EXAMPLE-FILE-B"

    get workspace_usage_path(@acorn)
    assert_select "section#chosen_dates", count: 0
    assert_select "section#this_month tbody th", text: "EXAMPLE-FILE-B"
    assert_select "section#last_month tbody th", text: "EXAMPLE-FILE-A"
  end

  private
    def use(agent, payer: nil, model: nil, tool: nil, input: 0, output: 0, cost: nil, file: nil, at:)
      agent.workspace.model_usages.create!(agent: agent, agent_name: agent.name, payer: payer, model: model, tool: tool,
        input: input, output: output, total_tokens: input + output, cost: cost, filed_under: file, created_at: at)
    end
end
