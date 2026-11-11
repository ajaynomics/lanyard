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
  # 2026-11-09: every message's time and the day between days, about 3 KB more.
  # Then the status line above the composer and the agent list's live states, about 6 KB more.
  # Then the messages waiting for the agent under its reply, and a helper's calls folded into its line, about 2 KB more.
  # 2026-11-10: typing survives a refresh (the composer kept, a focused text box left alone, no question to leave): about 0.5 KB.
  # Then a phone as iOS draws it: the stack's slide, the glass bar and sheet, the way back, what is pressed giving: about 5 KB of CSS.
  # 2026-11-10: the sidebar's edge resizes it, the side panel slides out in Safari and closes on a swipe, short row times: about 5 KB.
  # 2026-11-11: notifications that turn off with their reason, a swipe back that plays once, setting one's name: about 2 KB.
  # Then a phone's thread as the page itself, Jump to latest clear of the composer, and its bar as glass: about 1.5 KB.
  BUDGET = 274.kilobytes

  setup do
    install_sidecar_settings
    stub_request(:get, %r{#{SIDECAR}/v1/conversations/12}).to_return(body: { status: "idle", entries: [], cursor: nil, more: false }.to_json)
  end
  teardown { remove_sidecar_settings }

  test "an agent's thread loads within the budget, and the screen's viewer, the canvas, Settings' and a share's code only where they open" do
    sign_in_via_ajent
    conversation = create_conversation(User.find_by!(oidc_sub: "42").agents.sole) # tenancy-ok: test reads the person it signed in
    get conversation_path(conversation)
    assert_response :success

    files = css_select("link[rel=stylesheet], link[rel=modulepreload], script[src]").map { it["href"] || it["src"] }
    assert files.none? { it.include?("novnc") }, "noVNC (190 KB) is for the screen page alone"
    assert files.none? { it.include?("canvas") }, "the canvas's stylesheet and controllers come with the canvas"
    assert files.none? { it.match?(%r{/assets/(settings|share|pictures)\b}) }, "Settings' notifications, a share's pictures and making pictures smaller load where they are used"
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
