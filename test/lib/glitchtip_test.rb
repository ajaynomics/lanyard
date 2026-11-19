require "test_helper"

# An error report carries the breadcrumbs recorded before it. A query that
# writes a literal into its SQL would put whatever a person typed into the
# report, so no SQL may reach one.
class GlitchtipTest < ActiveSupport::TestCase
  test "a query's SQL, and the words in it, never reach an error report" do
    # Joined at run time: the report carries this file's source lines as
    # stack context, and the words must not be found there instead.
    words = [ "secret", "words" ].join(" ")

    with_sentry do |transport|
      ActiveRecord::Base.connection.select_value("SELECT #{ActiveRecord::Base.connection.quote(words)} AS body")
      Sentry.capture_message("something broke")

      event = transport.events.sole
      breadcrumbs = event.breadcrumbs.to_h[:values]
      assert_empty breadcrumbs.select { |crumb| crumb[:category].to_s.start_with?("sql.") || crumb[:data].to_h.keys.map(&:to_s).include?("sql") }
      assert_not_includes event.to_h.to_json, words
    end
  end

  private
    # Set up as config/initializers/glitchtip.rb does, but against an invented
    # DSN and a transport that only records, so nothing leaves the process.
    def with_sentry
      Sentry.init do |sentry|
        sentry.dsn = "https://public@glitchtip.example.com/1"
        sentry.transport.transport_class = Sentry::DummyTransport
        sentry.background_worker_threads = 0
        sentry.breadcrumbs_logger = [ :active_support_logger ]
        DurableAssistants::Glitchtip.apply(sentry)
      end
      require "sentry/rails/breadcrumb/active_support_logger"
      Sentry::Rails::Breadcrumb::ActiveSupportLogger.inject(Sentry.configuration.rails.active_support_logger_subscription_items)

      yield Sentry.get_current_client.transport
    ensure
      Sentry::Rails::Breadcrumb::ActiveSupportLogger.detach
      Sentry.close
    end
end
