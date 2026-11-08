require "test_helper"

# ACCESS__OWNER_EMAIL: an install that serves one person. Everyone it admits
# signs in as that person, to one set of agents, and is still let in, and may
# manage the model accounts, by their own email.
class InstallOwnerTest < ActionDispatch::IntegrationTest
  OWNER = "operator@example.com".freeze

  teardown { OmniAuth.config.mock_auth[:ajent] = nil }

  def sign_in(subject, email, name)
    reset!
    sign_in_via_ajent(subject:, email:, name:)
  end

  test "everyone admitted lands in the owner's agents, and the owner's name and email stay theirs" do
    with_setting(:access, :owner, OWNER) do
      sign_in "sub-maya", OWNER, "Maya"
      maya = User.find_by!(oidc_sub: "sub-maya") # tenancy-ok: test reads the person it signed in
      assert_equal [ "Assistant" ], maya.agents.pluck(:name)

      assert_no_difference -> { User.count } do # tenancy-ok: counts every person to prove none was made
        sign_in "sub-robin", "member@example.com", "Robin"
      end
      assert_select ".conversation-row__name", "Assistant"
      assert_equal [ OWNER, "Maya" ], maya.reload.values_at(:email, :name)
    end
  end

  test "someone who signs in before the owner ever has finds the owner's agents waiting, and the owner's first sign-in takes them" do
    with_setting(:access, :owner, OWNER) do
      sign_in "sub-robin", "member@example.com", "Robin"
      assert_select ".conversation-row__name", "Assistant"
      held = User.find_by!(email: OWNER) # tenancy-ok: the row held for the owner

      sign_in "sub-maya", OWNER, "Maya"
      assert_equal [ held.id, "sub-maya", "Maya" ], [ User.find_by!(oidc_sub: "sub-maya").id, held.reload.oidc_sub, held.name ] # tenancy-ok: test reads the person it signed in
      assert_equal 1, User.count # tenancy-ok: counts every person to prove none was made
    end
  end

  test "admission and the model accounts go by who signed in, not by the owner" do
    with_setting(:access, :owner, OWNER) do
      sign_in "sub-robin", "member@example.com", "Robin"
      get subscriptions_path
      assert_response :not_found, "Robin is not an admin, though the owner is"

      with_setting(:access, :emails, [ OWNER ]) do
        get root_path
        assert_redirected_to sign_in_path, "taking Robin off the list ends his session, though the owner is still on it"
      end

      sign_in "sub-maya", OWNER, "Maya"
      get settings_path
      assert_select "a[href=?]", subscriptions_path
    end
  end

  test "without an owner, each person has their own" do
    sign_in "sub-maya", OWNER, "Maya"
    sign_in "sub-robin", "member@example.com", "Robin"
    assert_equal 2, User.count # tenancy-ok: counts every person
  end
end
