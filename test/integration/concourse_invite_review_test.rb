require "test_helper"

class ConcourseInviteReviewTest < ActionDispatch::IntegrationTest
  LINK = "a#concourse_invite_review"

  setup do
    @concourse = Rails.application.config.x.concourse
    @previous_concourse = @concourse.dup
    @concourse.merge!(origin: "https://concourse.example.com", token_url: nil)
  end

  teardown do
    @concourse.replace(@previous_concourse)
    OmniAuth.config.mock_auth[:ajent] = nil
  end

  test "the owner can open Concourse without passing agent or account details" do
    agent = own_agent
    assert_empty agent.concourse_agents
    get agent_path(agent), params: { origin: "https://elsewhere.example.com", invite_email: "other@example.com" }

    assert_response :success
    assert_select LINK, count: 1 do |links|
      assert_equal "https://concourse.example.com/invite_destination", links.first["href"]
      assert_equal "false", links.first["data-turbo"]
      assert_equal "noreferrer", links.first["rel"]
    end
  end

  test "a workspace member and a signed-out visitor do not see the link" do
    agent = own_agent(shared: true)
    sign_in_via_ajent subject: "member", email: "member@example.com"
    member = User.find_by!(oidc_sub: "member") # tenancy-ok: the test reads its signed-in person
    agent.workspace.memberships.create!(user: member, role: "member")

    get agent_path(agent)
    assert_response :success
    assert_select LINK, count: 0

    open_session do |visitor|
      visitor.get agent_path(agent)
      visitor.assert_redirected_to sign_in_path
      visitor.assert_select LINK, count: 0
    end
  end

  test "another person using the single-owner account does not see the link" do
    access = Rails.application.config.x.access
    previous_owner = access[:owner]
    access[:owner] = "operator@example.com"
    agent = own_agent
    sign_in_via_ajent subject: "member", email: "member@example.com"

    get agent_path(agent)
    assert_response :success
    assert_select LINK, count: 0
  ensure
    access[:owner] = previous_owner
  end

  test "missing and untrusted origins do not offer a link" do
    agent = own_agent
    [ nil, "http://concourse.example.com", "https://", "//concourse.example.com",
      "https://user@concourse.example.com", "https://concourse.example.com/path",
      "https://concourse.example.com?x=1", "https://concourse.example.com#fragment",
      "https://concourse%2Eexample.com", "https://concourse.example.com:99999" ].each do |origin|
      @concourse[:origin] = origin
      get agent_path(agent)
      assert_response :success
      assert_select LINK, count: 0
    end
  end

  private
    def own_agent(shared: false)
      sign_in_via_ajent
      owner = User.find_by!(oidc_sub: "42") # tenancy-ok: the test reads its signed-in person
      return owner.agents.sole unless shared

      workspace = Workspace.make(name: "Team", owner: owner)
      owner.start_agent("Desk", workspace: workspace)
    end
end
