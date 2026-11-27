require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class InstructionRestorationTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  APPROVED = "Keep notes.\nCheck every date twice.\n\nReply in plain English."
  CURRENT = "Keep notes.\nCheck every date twice.\n\nReply in plain  English."
  CHANGE = [ [ "Reply in plain  English." ], [ "Reply in plain English." ] ]

  setup do
    install_sidecar_settings
    @owner = create_user(name: "Ari")
    @member = create_user(name: "Bev")
    @workspace = Workspace.make(name: "Studio", owner: @owner)
    @membership = @workspace.memberships.create!(user: @member, role: "member")
    @agent = @owner.start_agent("Editor", workspace: @workspace)
    @conversation = create_conversation(@agent)
    @call = 0
  end
  teardown { remove_sidecar_settings }

  test "a workspace member previews the personal change and confirms once without reverting other settings" do
    source, approval = approved_revision(@agent)
    write(@agent, CURRENT)
    @agent.update!(thinking_level: "high")
    sign_in(@member)
    get agent_instructions_path(@agent)
    assert_select "a[href=?]", agent_instruction_revisions_path(@agent)
    get agent_instruction_revisions_path(@agent)
    assert_select "a[href=?]", preview_path(@agent, source)
    token = preview(@agent, source)
    before = @agent.revisions.order(:id).pluck(:id, :instructions)

    assert_difference -> { @agent.revisions.count }, 1 do
      post restore_path(@agent, source), params: { review_token: token }
      assert_redirected_to agent_instructions_path(@agent)
    end
    assert_equal APPROVED, @agent.reload.instructions
    assert_equal "high", @agent.thinking_level
    assert_equal before, @agent.revisions.order(:id).pluck(:id, :instructions)[0...-1]
    assert_equal [ approval, @member, source.id ], latest(@agent).then { [ it.approval, it.restored_by, it.restored_from_id ] }
    get preview_path(@agent, source)
    assert_select "input[name=review_token]", count: 0, message: "a revision that already matches has nothing to confirm"

    write(@agent, CURRENT)
    assert_no_difference -> { @agent.revisions.count } do
      post restore_path(@agent, source), params: { review_token: token }
      assert_response :conflict
    end
    assert_equal CURRENT, @agent.reload.instructions
  end

  test "an unapproved, stale, tampered or other agent's review restores nothing" do
    source, = approved_revision(@agent)
    write(@agent, CURRENT)
    sign_in(@owner)
    get preview_path(@agent, latest(@agent))
    assert_response :not_found
    token = preview(@agent, source)
    other = @owner.start_agent("Reviewer", workspace: @workspace)
    post restore_path(other, source), params: { review_token: token }
    assert_response :not_found
    [ nil, "#{token}changed" ].each do |bad|
      post restore_path(@agent, source), params: { review_token: bad }
      assert_response :conflict
    end
    sign_in(@owner)
    write(@agent, CURRENT.sub("notes", "records"))
    write(@agent, CURRENT)
    post restore_path(@agent, source), params: { review_token: token }
    assert_response :conflict
    assert_equal CURRENT, @agent.reload.instructions
  end

  test "an approval from a prior workspace, or of other text, cannot be reviewed or restored" do
    source, = approved_revision(@agent)
    other_source, = approved_revision(@agent)
    write(@agent, CURRENT)
    sign_in(@owner)
    token = preview(@agent, source)
    post restore_path(@agent, other_source), params: { review_token: token }
    assert_response :conflict

    other_source.update_columns(instructions: "Not the approved text.")
    get agent_instruction_revisions_path(@agent)
    assert_select "a[href=?]", preview_path(@agent, source)
    assert_select "a[href=?]", preview_path(@agent, other_source), count: 0
    get preview_path(@agent, other_source)
    assert_response :not_found

    assert @agent.move_to(@owner.personal_workspace, by: @owner)
    get preview_path(@agent, source)
    assert_response :not_found
    post restore_path(@agent, source), params: { review_token: token }
    assert_response :not_found
    assert_equal CURRENT, @agent.reload.instructions
  end

  test "shared restore is owner-only, exact, and changes no agent's instructions" do
    source, approval = approved_revision(@workspace)
    personal = @agent.instructions
    write(@workspace, CURRENT)
    sign_in(@owner)
    get workspace_path(@workspace)
    assert_select "a[href=?]", workspace_instruction_revisions_path(@workspace)
    token = preview(@workspace, source)
    sign_in(@member)
    get preview_path(@workspace, source)
    assert_response :not_found
    post restore_path(@workspace, source), params: { review_token: token }
    assert_response :not_found
    sign_in(@owner)

    assert_difference -> { @workspace.revisions.count }, 1 do
      post restore_path(@workspace, source), params: { review_token: token }
      assert_redirected_to workspace_path(@workspace, anchor: "workspace_instructions")
    end
    assert_equal APPROVED, @workspace.reload.instructions
    assert_equal personal, @agent.reload.instructions
    assert_equal [ approval, @owner, @owner, source.id ], latest(@workspace).then { [ it.approval, it.restored_by, it.changed_by, it.restored_from_id ] }
    assert_no_difference -> { @workspace.revisions.count } do
      post restore_path(@workspace, source), params: { review_token: token }
      assert_response :conflict
    end
  end

  test "an expired shared review, another workspace's, or an owner who lost and regained that role must preview again" do
    source, = approved_revision(@workspace)
    write(@workspace, CURRENT)
    sign_in(@owner)
    token = preview(@workspace, source)
    get preview_path(Workspace.make(name: "Library", owner: @owner), source)
    assert_response :not_found
    travel 16.minutes do
      post restore_path(@workspace, source), params: { review_token: token }
      assert_response :conflict
    end

    token = preview(@workspace, source)
    @membership.take_ownership
    post restore_path(@workspace, source), params: { review_token: token }
    assert_response :not_found
    @workspace.memberships.find_by!(user: @owner).take_ownership
    post restore_path(@workspace, source), params: { review_token: token }
    assert_response :conflict
    assert_equal CURRENT, @workspace.reload.instructions
  end

  test "an approved revision still lists, reviews and restores after the week's prune clears its call" do
    [ @agent, @workspace ].each do |target|
      source, approval = approved_revision(target)
      write(target, CURRENT)
      travel Invocation::RESULTS_KEPT + 1.day do
        Invocation.prune_results
        assert_nil approval.invocation.reload.preview
        sign_in(@owner)
        get history_path(target)
        assert_select "a[href=?]", preview_path(target, source)
        post restore_path(target, source), params: { review_token: preview(target, source) }
        assert_response :see_other
        assert_equal APPROVED, target.reload.instructions
        assert latest(target).approved_text_for?(target, workspace: @workspace), "the restored copy stays approved"
      end
    end
  end

  private
    def approved_revision(target)
      write(target, APPROVED.sub("plain", "clear"))
      args = { "edits" => [ { "find" => "clear", "replace" => "plain" } ] }
      args["scope"] = "workspace" if target == @workspace
      call_id = "restore-source-#{@call += 1}"
      payload = invocation_payload(@conversation, tool: "change_yourself", arguments: args, call_id: call_id)
      receive = -> { Invocation.receive(@conversation, task_id: payload[:taskId], call_id: call_id, tool: "change_yourself", arguments: args, digest: payload[:digest]) }
      assert_equal "waiting", receive.call[:status]
      invocation = @conversation.invocations.find_by!(call_id: call_id)
      invocation.approve!(by: @owner)
      assert_equal({ "instructions" => "saved" }, receive.call[:result])
      [ latest(target), invocation.approval ]
    end

    def latest(target) = target.revisions.reorder(id: :desc).first!

    def write(target, text)
      target.reload
      target == @workspace ? target.change_instructions(text, by: @owner) : target.update!(instructions: text)
    end

    def sign_in(user) = sign_in_via_ajent(subject: user.oidc_sub, email: user.email, name: user.name)

    def history_path(target)
      target.is_a?(Workspace) ? workspace_instruction_revisions_path(target) : agent_instruction_revisions_path(target)
    end

    def preview_path(target, revision)
      target.is_a?(Workspace) ? new_workspace_instruction_revision_restoration_path(target, revision) : new_agent_instruction_revision_restoration_path(target, revision)
    end

    def restore_path(target, revision)
      target.is_a?(Workspace) ? workspace_instruction_revision_restoration_path(target, revision) : agent_instruction_revision_restoration_path(target, revision)
    end

    def preview(target, revision)
      get preview_path(target, revision)
      assert_response :success
      assert_equal [ "Removes", "Adds", "Instructions" ], css_select("#instruction_restore_diff dt").map { it.text.strip }
      assert_equal CHANGE, css_select("#instruction_restore_diff dd").first(2).map { it.css(".ui-fields__item").map(&:text) }
      assert_select "input[name=review_token]", count: 1
      css_select("input[name=review_token]").sole["value"]
    end
end
