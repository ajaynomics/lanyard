require "test_helper"

class AdmissionTest < ActiveSupport::TestCase
  test "admits the emails on the list, whatever their case" do
    with_setting(:access, :emails, %w[ sam@example.com maya@example.com ]) do
      assert Admission.admits?("sam@example.com")
      assert Admission.admits?("Maya@Example.com")
    end
  end

  test "admits nobody else, and nobody at all by default" do
    with_setting(:access, :emails, %w[ sam@example.com ]) do
      assert_not Admission.admits?("stranger@example.com")
      assert_not Admission.admits?("sam@example.com.evil.test")
      assert_not Admission.admits?("")
      assert_not Admission.admits?(nil)
    end
    with_setting(:access, :emails, []) { assert_not Admission.admits?("sam@example.com") }
  end

  test "an admin is admitted and on the admins list; nobody is one by default" do
    with_setting(:access, :emails, %w[ sam@example.com maya@example.com ]) do
      with_setting(:access, :admins, %w[ sam@example.com stranger@example.com ]) do
        assert Admission.admin?("Sam@Example.com")
        assert_not Admission.admin?("maya@example.com")
        assert_not Admission.admin?("stranger@example.com"), "the admins list admits nobody by itself"
        assert_not Admission.admin?(nil)
      end
      with_setting(:access, :admins, []) { assert_not Admission.admin?("sam@example.com") }
    end
  end

  test "admits an email invited to a shared workspace, once an admin approves, or a member of one, until it is removed from them all" do
    with_setting(:access, :emails, %w[ owner@example.com ]) do
      owner = User.create!(oidc_sub: "sub-owner", email: "owner@example.com")
      workspace = Workspace.create!(name: "Team")
      workspace.memberships.create!(user: owner, role: "owner")

      invitation = workspace.invitations.create!(email: "Guest@Example.com", inviter: owner)
      assert_not Admission.admits?("guest@example.com"), "not before an admin says yes"
      invitation.approve(by: owner)
      assert Admission.admits?("guest@example.com")
      assert Admission.admits?("GUEST@example.com")
      invitation.destroy!
      assert_not Admission.admits?("guest@example.com")

      guest = User.create!(oidc_sub: "sub-guest", email: "guest@example.com")
      membership = workspace.memberships.create!(user: guest, role: "member")
      assert Admission.admits?("guest@example.com")
      membership.destroy!
      assert_not Admission.admits?("guest@example.com")
    end
  end

  test "a personal workspace admits nobody, nor does a workspace in an install that serves one person" do
    with_setting(:access, :emails, []) do
      guest = User.create!(oidc_sub: "sub-guest", email: "guest@example.com")
      guest.personal_workspace
      assert_not Admission.admits?("guest@example.com"), "their personal workspace is not a way in"

      workspace = Workspace.create!(name: "Team")
      workspace.memberships.create!(user: guest, role: "owner")
      with_setting(:access, :owner, "owner@example.com") { assert_not Admission.admits?("guest@example.com") }
    end
  end
end
