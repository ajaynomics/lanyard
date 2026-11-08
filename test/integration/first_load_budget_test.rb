require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# What a phone downloads the first time it opens an agent: the page's
# stylesheets and every module the import map preloads. Over a phone network
# each kilobyte costs; this fails when that grows past the budget, so growth
# is a decision, not an accident. Repeat visits fetch none of it: the files
# are named by their digest and cached for a year.
class FirstLoadBudgetTest < ActionDispatch::IntegrationTest
  include AgentTestHelper

  # 2026-11-08: 212 KB (Turbo 103, Stimulus 45, the app's controllers 28, CSS 27), before compression.
  # Then Release 1a's bubbles, times, clean copying and shortcuts: about 10 KB more.
  BUDGET = 245.kilobytes

  setup do
    install_sidecar_settings
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { status: "idle", entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "an agent's thread loads within the budget, and the screen's viewer only on the screen" do
    sign_in_via_ajent
    conversation = create_conversation(User.find_by!(oidc_sub: "42").agents.sole) # tenancy-ok: test reads the person it signed in
    get conversation_path(conversation)
    assert_response :success

    files = css_select("link[rel=stylesheet], link[rel=modulepreload], script[src]").map { it["href"] || it["src"] }
    assert files.none? { it.include?("novnc") }, "noVNC (190 KB) is for the screen page alone"
    bytes = files.sum { asset_bytes(it) }
    assert_operator bytes, :<=, BUDGET, "first load is #{bytes / 1024} KB, over the #{BUDGET / 1024} KB budget"
  end

  test "an asset is cached for good, so a repeat visit downloads only the page" do
    sign_in_via_ajent
    get root_path
    asset = css_select("link[rel=modulepreload]").first["href"]
    get asset
    assert_response :success
    assert_match(/max-age=31536000/, response.headers["Cache-Control"])
    assert_match(/immutable/, response.headers["Cache-Control"])
  end

  private
    def asset_bytes(path)
      logical = path.delete_prefix("/assets/").sub(/-\h{8}(?=\.(js|css)\z)/, "")
      Rails.application.assets.load_path.find(logical)&.content&.bytesize or flunk "#{path} is not an asset this app serves"
    end
end
