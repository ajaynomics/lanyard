# After each visit turbo-rails waits for every <turbo-cable-stream-source> to
# be connected, and when one is not it says only "Item does not match the
# provided selector" (11 failures in CI). That cannot tell a subscription
# confirmed late from one never confirmed, so the failure goes on to say, for
# each source on the page, whether it is connected, its channel, the stream
# it names, where its subscription stands and how its cable stands, and how
# long the wait was.
module ExplainsUnconnectedStreamSources
  SOURCES = <<~'JS'
    [ ...document.querySelectorAll("turbo-cable-stream-source") ].map(source => {
      const subscription = source.subscription
      const subscriptions = subscription?.consumer?.subscriptions
      const connection = subscription?.consumer?.connection
      return {
        connected: source.hasAttribute("connected"),
        channel: source.getAttribute("channel"),
        signedStreamName: source.getAttribute("signed-stream-name"),
        subscription: !subscription ? "not made yet"
          : !subscriptions.subscriptions.includes(subscription) ? "rejected or removed"
          : subscriptions.guarantor?.pendingSubscriptions.includes(subscription) ? "awaiting confirmation"
          : "not awaiting confirmation",
        cable: connection ? connection.getState() || "no socket" : "unknown"
      }
    })
  JS

  def connect_turbo_cable_stream_sources(...)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    super
  rescue Capybara::ExpectationNotMet => error
    waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    raise error.class, "#{error.message}\n#{stream_sources_report(waited)}", error.backtrace
  end

  private
    def stream_sources_report(waited)
      page_age = page.evaluate_script("performance.now()") / 1000.0
      lines = page.evaluate_script(SOURCES).map do |source|
        stream = Turbo::StreamsChannel.verified_stream_name(source["signedStreamName"]) || "an unverifiable stream"
        "- #{source["connected"] ? "connected" : "not connected"}: #{source["channel"]} #{stream.inspect}, " \
          "subscription #{source["subscription"]}, cable #{source["cable"]}"
      end
      [ format("Stream sources after waiting %.1fs, %.1fs into the page:", waited, page_age), *lines ].join("\n")
    rescue Selenium::WebDriver::Error::WebDriverError => error
      "The page's stream sources could not be read: #{error.class}: #{error.message.lines.first}"
    end
end
