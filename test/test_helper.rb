ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
# Loaded before WebMock patches Net::HTTP: the sidecar's Unix socket client
# never leaves the machine, and its tests talk to a real local socket. (CI
# eager-loads it anyway; a local run would otherwise load it after.)
DurableAssistants::PiDurable::UnixHTTP
require "webmock/minitest"

# A test that needs the network is a test of someone else's uptime (S6).
# Localhost is the Capybara server and a local chromedriver. Everything else
# leaving the machine is a leaked call: providers are injected rather than
# stubbed over HTTP where possible, so a forgotten injection lands on this door
# instead of posting to a real API.
WebMock.disable_net_connect!(allow_localhost: true)

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # A setting changed for one block, as a deploy's ENV would change it.
    def with_setting(service, key, value)
      settings = Rails.application.config.x.public_send(service)
      previous = settings[key]
      settings[key] = value
      yield
    ensure
      settings[key] = previous
    end
  end
end

module OmniAuthTestHelper
  # Mirrors Ajent's shape: the UserInfo payload lands in extra.raw_info.
  def mock_ajent_auth(subject: "42", email: "operator@example.com", name: "Test Operator", email_verified: true,
                      issuer: Rails.application.config.x.oidc.issuer)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:ajent] = OmniAuth::AuthHash.new(
      provider: "ajent",
      uid: subject,
      info: { email: email, name: name },
      extra: {
        raw_info: {
          "iss" => issuer,
          "sub" => subject,
          "email" => email,
          "name" => name,
          "email_verified" => email_verified
        }
      }
    )
  end

  def sign_in_via_ajent(**options)
    mock_ajent_auth(**options)
    get "/auth/ajent/callback"
    follow_redirect! while response.redirect?
  end
end

class ActionDispatch::IntegrationTest
  include OmniAuthTestHelper
end
