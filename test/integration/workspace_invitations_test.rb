require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# The owner of a shared workspace invites people by email, removes members and
# cancels invitations (docs/design/workspaces.md). An invitation admits its
# email to the install; signing in with it, verified, makes the person a member.
# Removed from every shared workspace, a person admitted only that way is out.
class WorkspaceInvitationsTest < ActionDispatch::IntegrationTest
  include AgentTestHelper
  include ActionMailer::TestHelper

  NEWCOMER = "newcomer@example.com".freeze

  setup do
    install_sidecar_settings
    sign_in_via_ajent(name: "Owner")
    @owner = User.find_by!(oidc_sub: "42") # tenancy-ok: test reads the person it signed in
    post workspaces_path, params: { workspace: { name: "Household" } }
    @workspace = @owner.workspaces.find_by!(name: "Household")
    @agent = @workspace.agents.create!(user: @owner, name: "Shared", instructions: "Help.", model: Agent.models.first)
  end
  teardown { remove_sidecar_settings }

  test "a person makes a named workspace, owns it, and works in it" do
    assert_redirected_to workspace_path(@workspace)
    assert @workspace.owner_membership.user == @owner
    assert_not @workspace.personal?
    assert_equal @workspace.id, session[:workspace_id]

    post workspaces_path, params: { workspace: { name: " " } }
    assert_response :unprocessable_entity
  end

  test "a member renames a shared workspace; its owner renames their personal one, and nobody else can" do
    patch workspace_path(@workspace), params: { workspace: { name: "Home" } }
    assert_redirected_to workspace_path(@workspace)
    assert_equal "Home", @workspace.reload.name

    get edit_workspace_path(@owner.personal_workspace)
    assert_response :success
    sign_in_via_ajent(subject: "sub-outsider", email: "member@example.com", name: "Outsider")
    get edit_workspace_path(@owner.personal_workspace)
    assert_response :not_found
  end

  test "a failed rename says why once, under the field, and still names the workspace by its saved name" do
    patch workspace_path(@workspace), params: { workspace: { name: " " } }
    assert_response :unprocessable_entity
    assert_select ".field__error", count: 1, text: "Name can't be blank"
    assert_select "input#workspace_name + .field__error"
    assert_select "h1", "Rename Household"
    assert_select "title", /Rename Household/
    assert_select "a.app-header__back[href=?]", workspace_path(@workspace), text: "Household"
    assert_no_match "Owner", css_select("h1, a.app-header__back").map(&:text).join
  end

  test "the owner invites an email: it is admitted, and signing in with it, verified, lands them in the workspace as a member" do
    assert_not Admission.admits?(NEWCOMER)
    invite "NewComer@Example.com"
    assert_redirected_to workspace_path(@workspace)
    assert Admission.admits?(NEWCOMER), "the invitation admits the email, whatever its case"

    get workspace_path(@workspace)
    assert_select "li", text: /#{NEWCOMER}/

    newcomer = open_session { it.sign_in_via_ajent(name: "Newcomer", subject: "sub-newcomer", email: "Newcomer@example.com") }
    person = User.find_by!(oidc_sub: "sub-newcomer") # tenancy-ok: test reads the person it signed in
    assert_equal "member", @workspace.memberships.find_by!(user: person).role
    assert_empty @workspace.invitations, "the invitation became the membership"
    assert_equal @workspace.id, newcomer.session[:workspace_id]
    newcomer.get conversation_path(@agent.conversation)
    assert_equal 200, newcomer.response.status
  end

  test "inviting someone already signed in makes them a member at once, without waiting for their next sign-in" do
    create_user(name: "Member", email: "member@example.com")
    known = open_session { it.sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com") }
    person = User.find_by!(oidc_sub: "sub-member") # tenancy-ok: test reads the person it signed in

    invite "Member@Example.com"
    assert_redirected_to workspace_path(@workspace)
    assert_equal "member", @workspace.memberships.find_by!(user: person).role
    assert_empty @workspace.invitations

    known.get workspace_path(@workspace)
    known.get conversation_path(@agent.conversation)
    assert_equal 200, known.response.status
  end

  test "an unverified email, or another one, gets no membership" do
    invite NEWCOMER

    unverified = open_session { it.sign_in_via_ajent(subject: "sub-newcomer", email: NEWCOMER, email_verified: false) }
    assert_nil unverified.session[:user_id]
    assert_nil User.find_by(oidc_sub: "sub-newcomer") # tenancy-ok: test checks nobody was made

    other = open_session { it.sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com") }
    assert other.session[:user_id]
    assert_not @workspace.member?(User.find_by!(oidc_sub: "sub-member")) # tenancy-ok: test reads the person it signed in
    assert_equal 1, @workspace.invitations.count
  end

  test "the mailer sends the invited email one message with the workspace's link" do
    with_setting(:mail, :smtp_address, "smtp.example.com") do
      assert_emails(1) { invite NEWCOMER }
    end
    mail = ActionMailer::Base.deliveries.last
    assert_equal [ NEWCOMER ], mail.to
    assert_includes mail.body.to_s, "http://example.com/workspaces/#{@workspace.id}"
    assert_includes mail.subject, "Household"
  end

  test "an owner who is not an admin invites: the email cannot sign in, nor is mailed, until an admin approves in Settings" do
    with_setting(:mail, :smtp_address, "smtp.example.com") do
      reset!
      sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
      post workspaces_path, params: { workspace: { name: "Club" } }
      club = Workspace.find_by!(name: "Club") # tenancy-ok: test reads the workspace it made

      assert_no_emails { post workspace_invitations_path(club), params: { invitation: { email: NEWCOMER } } }
      assert_not Admission.admits?(NEWCOMER)
      follow_redirect!
      assert_match "They can sign in once an admin approves it.", response.body
      assert_select "#invitations li", text: /Waiting for an admin to approve it/
      get settings_invitations_path
      assert_response :not_found, "only an admin sees the invitations waiting"
      invitation = club.invitations.sole
      post settings_invitation_approval_path(invitation)
      assert_response :not_found

      refused = open_session { it.sign_in_via_ajent(name: "Newcomer", subject: "sub-newcomer", email: NEWCOMER) }
      assert_nil refused.session[:user_id], "refused like any email not let in"
      assert_nil User.find_by(oidc_sub: "sub-newcomer") # tenancy-ok: test checks nobody was made

      reset!
      sign_in_via_ajent(name: "Owner")
      get settings_invitations_path
      assert_select "li", text: /#{NEWCOMER}.*Club/m
      assert_emails(1) { post settings_invitation_approval_path(invitation) }
      assert_redirected_to settings_invitations_path
      assert_equal [ NEWCOMER ], ActionMailer::Base.deliveries.last.to
      assert_equal @owner, invitation.reload.approver
      assert Admission.admits?(NEWCOMER)
      follow_redirect!
      assert_select "li", text: /#{NEWCOMER}/, count: 0
      assert_no_emails { post settings_invitation_approval_path(invitation) }
      assert_response :not_found, "approved once, mailed once"

      admitted = open_session { it.sign_in_via_ajent(name: "Newcomer", subject: "sub-newcomer", email: NEWCOMER) }
      assert admitted.session[:user_id]
      assert_equal club.id, admitted.session[:workspace_id]
      assert club.member?(User.find_by!(oidc_sub: "sub-newcomer")) # tenancy-ok: test reads the person it signed in
    end
  end

  test "with no mail going out, a non-admin's invitation still waits for an admin before its email can sign in" do
    reset!
    sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
    post workspaces_path, params: { workspace: { name: "Club" } }
    club = Workspace.find_by!(name: "Club") # tenancy-ok: test reads the workspace it made
    post workspace_invitations_path(club), params: { invitation: { email: NEWCOMER } }
    assert_not Admission.admits?(NEWCOMER)

    reset!
    sign_in_via_ajent(name: "Owner")
    assert_no_emails { post settings_invitation_approval_path(club.invitations.sole) }
    assert Admission.admits?(NEWCOMER)
  end

  test "a person no longer let in is not let back in by a non-admin's invitation before an admin approves it" do
    gone = create_user(name: "Gone", email: "gone@example.com")
    reset!
    sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
    post workspaces_path, params: { workspace: { name: "Club" } }
    club = Workspace.find_by!(name: "Club") # tenancy-ok: test reads the workspace it made
    post workspace_invitations_path(club), params: { invitation: { email: gone.email } }
    assert_not club.member?(gone)
    assert_not Admission.admits?(gone.email)
    assert_equal 1, club.invitations.count
  end

  test "an admin's own invitation is emailed at once; an admin may decline another's, which ends its admission" do
    with_setting(:mail, :smtp_address, "smtp.example.com") do
      assert_emails(1) { invite "first@example.com" }
      assert @workspace.invitations.sole.approved_at

      club = Workspace.create!(name: "Club").tap { it.memberships.create!(user: create_user(name: "Member", email: "member@example.com"), role: "owner") }
      waiting = club.invitations.create!(email: NEWCOMER, inviter: club.owner)
      get settings_invitations_path
      assert_select "li", text: /first@example.com/, count: 0
      delete settings_invitation_path(waiting)
      assert_redirected_to settings_invitations_path
      assert_not Admission.admits?(NEWCOMER)
    end
  end

  test "with no mail going out, the page shows the link to share instead" do
    assert_no_emails { invite NEWCOMER }
    follow_redirect!
    assert_select "code", text: "http://www.example.com/workspaces/#{@workspace.id}"
  end

  test "an email already a member is not invited again" do
    member = join_listed_member
    invite member.email
    assert_response :unprocessable_entity
    assert_empty @workspace.invitations
  end

  test "a member cannot invite, remove or cancel; they can leave" do
    invite NEWCOMER
    invitation = @workspace.invitations.sole
    other = @workspace.memberships.create!(user: create_user(name: "Other"), role: "member")
    member = join_listed_member

    reset!
    sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
    post workspace_invitations_path(@workspace), params: { invitation: { email: "stranger@example.com" } }
    assert_response :not_found
    delete workspace_invitation_path(@workspace, invitation)
    assert_response :not_found
    delete workspace_membership_path(@workspace, other)
    assert_response :forbidden
    delete workspace_membership_path(@workspace, @workspace.owner_membership)
    assert_response :forbidden
    assert_equal 3, @workspace.memberships.count
    assert @workspace.invitations.exists?(invitation.id)
    assert_not Admission.admits?("stranger@example.com")

    delete workspace_membership_path(@workspace, @workspace.memberships.find_by!(user: member))
    assert_redirected_to root_path
    assert_not @workspace.member?(member)
  end

  test "the owner cannot remove themselves" do
    delete workspace_membership_path(@workspace, @workspace.owner_membership)
    assert_response :forbidden
    assert_equal @owner, @workspace.reload.owner
  end

  test "the owner hands the workspace to a member, stays as a member and may then leave; the new owner invites and removes" do
    member = join_listed_member
    get workspace_path(@workspace)
    assert_select "button", text: "Make owner", count: 1

    post workspace_membership_ownership_path(@workspace, @workspace.memberships.find_by!(user: member))
    assert_redirected_to workspace_path(@workspace)
    assert_equal member, @workspace.reload.owner
    assert_equal "member", @workspace.memberships.find_by!(user: @owner).role

    invite NEWCOMER
    assert_response :not_found, "the former owner no longer invites"
    get workspace_path(@workspace)
    assert_select "button", text: "Make owner", count: 0

    reset!
    sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
    invite NEWCOMER
    assert_redirected_to workspace_path(@workspace)

    reset!
    sign_in_via_ajent(name: "Owner")
    delete workspace_membership_path(@workspace, @workspace.memberships.find_by!(user: @owner))
    assert_redirected_to root_path
    assert_not @workspace.member?(@owner)
  end

  test "a member cannot make anyone the owner" do
    member = join_listed_member
    other = @workspace.memberships.create!(user: create_user(name: "Other"), role: "member")

    reset!
    sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
    post workspace_membership_ownership_path(@workspace, other)
    assert_response :not_found
    post workspace_membership_ownership_path(@workspace, @workspace.memberships.find_by!(user: member))
    assert_response :not_found
    assert_equal @owner, @workspace.reload.owner
  end

  test "removed, a person admitted only through the workspace is signed out on their next request" do
    invite NEWCOMER
    newcomer = open_session { it.sign_in_via_ajent(name: "Newcomer", subject: "sub-newcomer", email: NEWCOMER) }
    person = User.find_by!(oidc_sub: "sub-newcomer") # tenancy-ok: test reads the person it signed in

    delete workspace_membership_path(@workspace, @workspace.memberships.find_by!(user: person))
    assert_redirected_to workspace_path(@workspace)
    assert_not Admission.admits?(NEWCOMER)

    newcomer.get conversation_path(@agent.conversation)
    assert_equal 303, newcomer.response.status
    assert_equal sign_in_url, newcomer.response.location
    assert_nil newcomer.session[:user_id]
  end

  test "leaving their last shared workspace, someone admitted only through it is warned first, then signed out with why" do
    invite NEWCOMER
    newcomer = open_session { it.sign_in_via_ajent(name: "Newcomer", subject: "sub-newcomer", email: NEWCOMER) }
    membership = @workspace.memberships.find_by!(user: User.find_by!(oidc_sub: "sub-newcomer")) # tenancy-ok: test reads the person it signed in

    newcomer.get workspace_path(@workspace)
    newcomer.assert_select "button[data-turbo-confirm*='can no longer sign in here']", text: "Leave"

    newcomer.delete workspace_membership_path(@workspace, membership)
    assert_equal sign_in_url, newcomer.response.location
    assert_nil newcomer.session[:user_id]
    newcomer.follow_redirect!
    assert_match "You left Household, and with it this install.", newcomer.response.body
  end

  test "a member on the install's list is not warned of losing it" do
    member = join_listed_member
    listed = open_session { it.sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com") }
    listed.get workspace_path(@workspace)
    listed.assert_select "button[data-turbo-confirm='Leave Household?']", text: "Leave"
    listed.delete workspace_membership_path(@workspace, @workspace.memberships.find_by!(user: member))
    assert_equal root_url, listed.response.location
  end

  test "removed, a person on the install's list keeps their personal workspace" do
    member = join_listed_member
    listed = open_session do
      it.sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com")
      it.get workspace_path(@workspace)
    end

    delete workspace_membership_path(@workspace, @workspace.memberships.find_by!(user: member))

    listed.get conversation_path(@agent.conversation)
    assert_equal 404, listed.response.status
    assert_equal member.personal_workspace.id, listed.session[:workspace_id]
    listed.get root_path
    assert_equal 200, listed.response.status
  end

  test "cancelling an invitation ends its admission" do
    invite NEWCOMER
    delete workspace_invitation_path(@workspace, @workspace.invitations.sole)
    assert_redirected_to workspace_path(@workspace)
    assert_not Admission.admits?(NEWCOMER)

    refused = open_session { it.sign_in_via_ajent(subject: "sub-newcomer", email: NEWCOMER) }
    assert_nil refused.session[:user_id]
  end

  test "nobody outside the workspace sees its members page" do
    stranger = open_session { it.sign_in_via_ajent(name: "Member", subject: "sub-member", email: "member@example.com") }
    stranger.get workspace_path(@workspace)
    assert_equal 404, stranger.response.status
  end

  private
    def invite(email)
      post workspace_invitations_path(@workspace), params: { invitation: { email: email } }
    end

    def join_listed_member
      create_user(name: "Member", email: "member@example.com").tap { @workspace.memberships.create!(user: it, role: "member") }
    end
end
