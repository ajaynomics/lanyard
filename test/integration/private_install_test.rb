require "test_helper"

# An install is one person's own: nothing in it is for a search engine.
class PrivateInstallTest < ActionDispatch::IntegrationTest
  test "every page says not to index it, in its header and its meta" do
    get sign_in_path
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    assert_select "meta[name=robots][content=?]", "noindex, nofollow"
    assert_select "title", "Sign in · #{DurableAssistants.config(:app, :name)}"

    get icon_path("app", format: :png)
    assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
  end

  test "robots.txt turns every crawler away, and there is no sitemap" do
    robots = Rails.public_path.join("robots.txt").read
    assert_match %r{^User-agent: \*\nDisallow: /$}, robots
    assert_no_match(/sitemap/i, robots.lines.grep_v(/\A#/).join)
    assert_not Rails.public_path.join("sitemap.xml").exist?
  end

  test "the install sheet shows the icon in the accent and pictures of the app" do
    get pwa_manifest_path(format: :json)
    manifest = response.parsed_body
    assert_equal %w[ narrow wide ], manifest["screenshots"].pluck("form_factor").sort
    manifest["screenshots"].each { assert Rails.public_path.join(it["src"].delete_prefix("/")).exist?, it["src"] }
    manifest["icons"].each do |icon|
      get icon["src"]
      assert_response :success, icon["src"]
    end
  end
end
