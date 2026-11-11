require "test_helper"

# Without Cloudflare Access in front, every route faces the internet. Each one
# either needs a signed-in, admitted person or is listed here with what guards
# it instead (docs/open-routes.md says the same, for people).
class OpenRoutesTest < ActionDispatch::IntegrationTest
  OPEN = {
    "GET /sign_in" => "nothing to see but a button; rate limited",
    "POST /auth/ajent" => "OmniAuth's request phase: a CSRF token, then Ajent; rate limited",
    "GET /auth/ajent/callback" => "Ajent's signed answer and ACCESS__EMAILS; rate limited",
    "GET /auth/failure" => "says sign-in did not complete; rate limited",
    "POST /campfire/:token" => "the bot's secret token; rate limited per address and per token",
    "POST /concourse/:id/push" => "the agent's push token, compared in constant time; rate limited per address and per agent",
    "POST /agent/accesses" => "inside the host only, and RAILS_TOKEN",
    "POST /agent/invocations" => "inside the host only, and RAILS_TOKEN",
    "POST /agent/frames" => "inside the host only, and RAILS_TOKEN",
    "POST /agent/syncs" => "inside the host only, and RAILS_TOKEN",
    "POST /agent/sign_ins" => "inside the host only, and RAILS_TOKEN",
    "POST /agent/cards" => "inside the host only, and RAILS_TOKEN",
    "POST /agent/files" => "inside the host only, and RAILS_TOKEN",
    "POST /agent/uploads" => "inside the host only, and RAILS_TOKEN",
    "GET /up" => "says the app booted, nothing more",
    "GET /manifest" => "the app's name and icon",
    "GET /service-worker" => "a static script",
    "GET /configurations/:id" => "a Hotwire Native app's fixed path rules",
    "GET /connectors/client" => "the install's Client ID Metadata Document: its name and callback, the same for everyone",
    "GET /icons/:id" => "the icon in the accent, from fixed names only",
    "GET /favicon.ico" => "the icon in the accent",
    "GET /apple-touch-icon.png" => "the icon in the accent",
    "GET /claude_subscription" => "a redirect to /subscriptions, which needs sign-in",
    "GET /recede_historical_location" => "Turbo Native's empty page",
    "GET /resume_historical_location" => "Turbo Native's empty page",
    "GET /refresh_historical_location" => "Turbo Native's empty page"
  }.freeze

  # Rails' own routes, refused by Rails: the mail ingresses answer 404 until one
  # is configured (mail arrives by IMAP), and the conductor only in development.
  REFUSED_BY_RAILS = %r{\A/rails/(action_mailbox|conductor)/}

  def routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.delete_suffix("(.:format)")
      next if route.verb.blank? || path == "/(*path)" # APP__REDIRECTS' hosts only (app_redirects_test.rb)
      [ "#{route.verb} #{path}", route.verb, path ]
    end.uniq
  end

  test "every route needs a signed-in person, or is listed with its guard" do
    open = []
    routes.each do |name, verb, path|
      next if path.match?(REFUSED_BY_RAILS) || OPEN.key?(name)
      process verb.downcase.to_sym, path.gsub(/[:*]\w+/, "1")
      # Not a 404: an unguarded route that finds no record 1 answers 404 too.
      # Routes whose own token turns a stranger away with 404 are listed in OPEN.
      refused = response.redirect? && response.location == sign_in_url || response.status.in?([ 401, 403 ])
      open << name unless refused
    end
    assert_empty open - OPEN.keys, "answers without a signed-in person, and is not listed in OpenRoutesTest::OPEN or docs/open-routes.md"
    assert_empty OPEN.keys - routes.map(&:first), "listed as open, but there is no such route"
  end

  test "Rails' own mail and conductor routes refuse everyone here" do
    routes.select { |_, _, path| path.match?(REFUSED_BY_RAILS) }.each do |name, verb, path|
      process verb.downcase.to_sym, path.gsub(/[:*]\w+/, "1")
      assert_includes [ 403, 404 ], response.status, name
    end
  end

  test "docs/open-routes.md lists every open route" do
    doc = Rails.root.join("docs/open-routes.md").read
    OPEN.each_key { assert_includes doc, "`#{it}`" }
  end
end
