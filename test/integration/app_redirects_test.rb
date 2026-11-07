require "test_helper"

class AppRedirectsTest < ActionDispatch::IntegrationTest
  test "another name for the app only sends people to its own address, path and query kept, before sign-in" do
    with_setting(:app, :redirects, "staff.example.com, old.example.com") do
      host! "staff.example.com"
      get "/agents/3/edit?tab=notes"
      assert_redirected_to "http://localhost/agents/3/edit?tab=notes"
      assert_response :found

      host! "old.example.com"
      post "/sign_out"
      assert_redirected_to "http://localhost/sign_out"

      host! "www.example.com"
      get "/up"
      assert_response :success
    end
  end
end
