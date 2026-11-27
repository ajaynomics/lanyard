require "test_helper"
require_relative "test_helpers/chrome_shared_memory"
require_relative "test_helpers/explains_unconnected_stream_sources"

# Capybara's default server is Puma. This app is Falcon, so the browser tests
# drive the server production runs.
Capybara.register_server :falcon do |app, port, host|
  require "rackup/handler/falcon"
  Rackup::Handler::Falcon.run(app, Host: host, Port: port)
end
Capybara.server = :falcon

# This machine's Chromium is /usr/bin/chromium; CI's comes from setup-chrome,
# which says where it put Chrome and its driver (CHROME_BIN, CHROMEDRIVER_PATH).
# Naming the driver stops Selenium Manager reaching for the network to find one.
driver = ENV.fetch("CHROMEDRIVER_PATH") { %w[/usr/bin/chromedriver /usr/local/bin/chromedriver].find { |path| File.executable?(path) } }
Selenium::WebDriver::Chrome::Service.driver_path = driver if driver

# chromedriver makes each browser a fresh profile in TMPDIR and removes it at
# quit. A form's POST goes through that profile's HTTP cache before it is sent,
# and in CI /tmp is on the disk the jobs contend for: a stall there held forms
# busy past every wait, and a new browser's first page past Selenium's 30
# seconds (CI 10253, 10256, 10265). With room in /dev/shm the profiles, and
# these tests' other scratch files, are kept there instead.
ENV["TMPDIR"] = "/dev/shm" if ChromeSharedMemory.room?

# A Turbo refresh replaces the page while Capybara is checking an element, and
# Chrome says so with an "unknown error" ("Node with given id does not belong
# to the document") that Capybara does not know to retry. It is a stale
# element, so Selenium is told to report it as one and Capybara retries.
module DetachedNodeIsStale
  MESSAGE = "does not belong to the document"

  def error
    found = super
    return found unless found.is_a?(Selenium::WebDriver::Error::UnknownError) && found.message.to_s.include?(MESSAGE)
    Selenium::WebDriver::Error::StaleElementReferenceError.new(found.message)
  end
end
Selenium::WebDriver::Remote::Response.prepend(DetachedNodeIsStale)

# Capybara's evaluate_async_script sets the browser's script timeout to its
# own short wait and never puts it back. The browser lives across tests, so
# every later script had two seconds rather than thirty (CI run 10181).
module RestoresScriptTimeout
  def evaluate_async_script(...)
    timeouts = browser.manage.timeouts
    before = timeouts.script
    super
  ensure
    timeouts.script = before if before
  end
end
Capybara::Selenium::Driver.prepend(RestoresScriptTimeout)

require "turbo/system_test_helper"
Turbo::SystemTestHelper.prepend(ExplainsUnconnectedStreamSources)

# Turbo can show the next page before it lets that page take clicks: while
# <html aria-busy> stands, Chrome hands a click to the page being replaced
# (CI 9457, 9458). And each Stimulus controller arrives by its own import
# (eagerLoadControllersFrom), so a page can take a key press, a click or typing
# before the controller that answers it has connected, and it is lost: ⌘, went
# to a page with no shortcuts yet. Every action waits for both, checked on the
# whole document so one inside `within` waits too.
#
# Only identifiers the import map provides as controllers/*_controller are
# awaited: the rest come with a module of their own (settings.js, native.js)
# or never in this browser, and waiting for them could hang.
#
# A browser's own form submission holds the click until the server answers
# and the next page loads, as a visit does. Turbo sends the form by fetch, so
# the click returned at once, and the next check spent its own wait on the
# server: on a loaded CI it ran out first (CI 9895, 9908). So an action then
# waits, as a visit does, for the answer (no form[aria-busy], none still
# being read), and then for the visit that draws it (html[aria-busy]). Turbo
# ends a submission (turbo:submit-end) before it reads the answer and starts
# that visit, so answers being read are counted from the first check on a
# page, before any action there.
#
# A turbo-frame loads and draws on its own, and no html[aria-busy] covers it:
# Turbo clears the frame's aria-busy before reading the answer, then draws it
# at a later repaint, and a lazy frame starts only when the browser's
# intersection check finds it shown. Choosing History returned while its
# versions loaded, and the next check spent its wait on them (CI 10151). So
# the drawn check lets that intersection check run, for any lazy frame to
# start, and then waits for every frame loading or drawing.
module ActOnSettledPage
  UNSETTLED = <<~'JS'
    (() => {
      window.formAnswersBeingRead ??= (() => {
        const reading = new Set
        addEventListener("turbo:submit-end", ({ detail: { fetchResponse } }) => {
          const html = fetchResponse?.responseHTML
          if (!html) return
          reading.add(html)
          html.finally(() => setTimeout(() => reading.delete(html)))
        })
        return reading
      })()
      window.framesInFlight ??= (() => {
        const frames = { loading: new Set, drawing: new Set }
        addEventListener("turbo:before-fetch-request", ({ target }) => target.localName == "turbo-frame" && frames.loading.add(target))
        addEventListener("turbo:before-frame-render", ({ target }) => frames.drawing.add(target))
        addEventListener("turbo:frame-render", ({ target }) => frames.drawing.delete(target))
        return frames
      })()
      if (document.documentElement.hasAttribute("aria-busy")) return [ "html[aria-busy]" ]
      const importmap = document.querySelector("script[type=importmap]")
      if (!importmap) return []
      if (!window.Stimulus) return [ "Stimulus" ]
      const provided = Object.keys(JSON.parse(importmap.text).imports)
        .map(path => path.match(/^controllers\/(.+)_controller$/)?.[1]).filter(Boolean)
        .map(name => name.replace(/\//g, "--").replace(/_/g, "-"))
      return [ ...document.querySelectorAll("[data-controller]") ].flatMap(element =>
        element.getAttribute("data-controller").split(/\s+/)
          .filter(identifier => provided.includes(identifier) && !Stimulus.getControllerForElementAndIdentifier(element, identifier)))
    })()
  JS

  ANSWERED = <<~'JS'
    (() => {
      if (document.querySelector("form[aria-busy]")) return [ "form[aria-busy]" ]
      if (window.formAnswersBeingRead?.size) return [ "a form's answer" ]
      return []
    })()
  JS

  DRAWN = <<~'JS'
    const done = arguments[arguments.length - 1]
    const unsettled = () => {
      const { drawing = [], loading = [] } = window.framesInFlight ?? {}
      const frames = [ ...drawing, ...[ ...loading ].filter(frame => frame.matches("[src]:not([complete])")) ]
      return [
        ...document.documentElement.hasAttribute("aria-busy") ? [ "html[aria-busy]" ] : [],
        ...frames.filter(frame => frame.isConnected).map(frame => `turbo-frame#${frame.id}`)
      ]
    }
    const lazy = document.querySelectorAll("turbo-frame[loading=lazy][src]:not([complete])")
    if (!lazy.length) return done(unsettled())
    const seen = new IntersectionObserver(() => { seen.disconnect(); setTimeout(() => done(unsettled())) })
    lazy.forEach(frame => seen.observe(frame))
  JS

  # Its own loop, not Capybara's synchronize: inside another one (choose clicks
  # its label within a synchronize) that checks once and lets the action return.
  def self.wait(session, script = UNSETTLED)
    deadline = Capybara::Helpers.monotonic_time + Capybara.default_max_wait_time
    loop do
      unsettled = begin
        script == DRAWN ? session.evaluate_async_script(script) : session.evaluate_script(script)
      rescue Selenium::WebDriver::Error::JavascriptError, Selenium::WebDriver::Error::ScriptTimeoutError => error # the page went away, or stalled, mid-check
        [ error.message ]
      end
      return if unsettled.empty?
      raise Capybara::ExpectationNotMet, "The page is not settled: #{unsettled.uniq.join(", ")}" if Capybara::Helpers.monotonic_time > deadline
      sleep Capybara.default_retry_interval
    end
  end

  %i[ click send_keys set select_option ].each do |action|
    define_method(action) do |*args, **options, &block|
      ActOnSettledPage.wait(session)
      super(*args, **options, &block).tap do
        ActOnSettledPage.wait(session, ANSWERED)
        ActOnSettledPage.wait(session, DRAWN)
      end
    end
  end
end
Capybara::Node::Element.prepend(ActOnSettledPage)

# The browser's own navigations act too: a back taken while the last visit
# still draws is taken from that visit (CI 9733). And each returns at the load
# event, before the controllers connect, so a rect or script read straight
# after reads a page still changing (CI 9877). So each waits after, and each
# but a visit, which may leave a page mid-request on purpose, waits before.
module NavigateSettledPage
  %i[ visit refresh go_back go_forward ].each do |navigation|
    define_method(navigation) do |*args, **options, &block|
      ActOnSettledPage.wait(self) unless navigation == :visit
      super(*args, **options, &block).tap { ActOnSettledPage.wait(self) }
    end
  end
end
Capybara::Session.prepend(NavigateSettledPage)

# Capybara clears a reused browser's session but leaves its window size behind.
# Remember only windows a test resizes, including those with a phone default.
module RestoreResizedBrowserWindows
  def resize_window_to(handle, width, height)
    (@original_window_sizes ||= {})[handle] ||= window_size(handle)
    super
  end

  def restore_resized_windows
    return unless @original_window_sizes

    window_handles.each do |handle|
      size = @original_window_sizes[handle]
      resize_window_to(handle, *size) if size && window_size(handle) != size
    end
  ensure
    @original_window_sizes = nil
  end
end
Capybara::Selenium::Driver.prepend(RestoreResizedBrowserWindows)

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # One browser at a time, as when there were fewer than Rails' threshold of
  # 50 of these: past it, every test got its own Chrome at once, and on a busy
  # machine unrelated ones failed by chance (a click that landed mid-visit).
  parallelize(workers: 1)

  # Selenium waits two minutes for each answer from the browser. One that has
  # stopped answering answers nothing again, so a shorter wait bounds what it
  # costs before it is let go (after_teardown).
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1400 ], options: { timeout: 30 } do |options|
    chromium = ENV.fetch("CHROME_BIN") { %w[/usr/bin/chromium /usr/bin/chromium-browser /usr/bin/google-chrome /usr/bin/google-chrome-stable].find { |path| File.executable?(path) } }
    options.binary = chromium if chromium
    options.add_argument("--no-sandbox")
    ChromeSharedMemory.arguments.each { options.add_argument(it) }
    options.add_argument("--force-prefers-reduced-motion")
    options.add_option("goog:loggingPrefs", { browser: "ALL" })
  end

  include OmniAuthTestHelper

  # The app's public address is the test server's, as APP__URL is the real one's:
  # OmniAuth builds its redirects on it.
  setup do
    @app_url = Rails.application.config.x.app[:url]
    Rails.application.config.x.app[:url] = Capybara.current_session.server.base_url
  end
  teardown { Rails.application.config.x.app[:url] = @app_url }

  # Where this test's part of log/test.log begins (save_test_log).
  def before_setup
    @test_log_start = File.size?(test_log) || 0
    super
  end

  # A test can end while its last request is still being answered (one that
  # checks what reached the sidecar, say). Capybara clears the browser's
  # cookies first, then that answer's session cookie arrives, and the next
  # test starts signed in as someone the rollback removed (#61). The answer
  # comes first; Capybara's reset follows in super.
  #
  # A browser that stopped answering is let go, so the next test starts a
  # fresh one rather than waiting it out on every command (CI run 8303).
  def after_teardown
    session = Capybara.current_session
    session.server&.wait_for_pending_requests
    super
    session.driver.restore_resized_windows if session.driver.respond_to?(:restore_resized_windows)
  rescue Net::ReadTimeout
    quit_browser
    raise
  end

  # Asking a browser that stopped answering for a picture only waits again.
  # Beside the picture go the page and what its console said, so a failure in
  # CI shows what the browser saw: CI run 8909 kept nothing to say why. And
  # the test's own part of log/test.log, which says what the server and its
  # cable did: the whole log is tens of megabytes (CI run 10181).
  def take_failed_screenshot
    save_test_log if failed?
    return if failures.any? { it.error.is_a?(Net::ReadTimeout) }
    super
    save_failure_evidence if failed? && Capybara::Session.instance_created?
  end

  # The page shows a message the moment it is sent, before the request
  # reaches the server: a test that checks the request waits for it.
  # A change shown by broadcast alone (Message, Cancel) is missed if the page's
  # streams are not connected yet when it is pressed.
  def wait_for_live_updates = assert_no_selector("turbo-cable-stream-source:not([connected])", visible: :all)

  # Turbo can expose the destination before it lets the new page receive clicks
  # (ActOnSettledPage); for a test that acts some other way.
  def wait_for_settled_turbo = ActOnSettledPage.wait(page)

  # Fails, saying what it waited for, when the time runs out: a wait that ran
  # out quietly let the test go on and fail later at something else (CI 10108,
  # an empty list at canvas_test's `sent.sole`).
  def wait_until(what = nil, within: Capybara.default_max_wait_time, &condition)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
    sleep 0.05 until (met = condition.call) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    assert met, "waited #{within} seconds for #{what || "the condition at #{condition.source_location.join(":").delete_prefix("#{Rails.root}/")}"}"
  end

  # The composer as a person meets it: its controller connected (Enter sends)
  # and no message of its own on the way.
  def wait_for_ready_composer
    wait_until("the composer to be ready") do
      page.evaluate_script("!!window.Stimulus?.getControllerForElementAndIdentifier(document.querySelector('#composer:not([aria-busy])'), 'composer')")
    end
  end

  def sign_in_via_ajent(**options)
    mock_ajent_auth(**options)
    visit "/auth/ajent/callback"
  end

  private
    def save_failure_evidence
      save_html
      File.write("#{absolute_path}.console.log", browser_console)
    end

    def save_test_log
      FileUtils.mkdir_p(File.dirname(absolute_path))
      File.open(test_log) do |log|
        log.seek([ @test_log_start.to_i, log.size ].min)
        File.write("#{absolute_path}.log", log.read)
      end
    end

    def test_log = Rails.application.paths["log"].first

    def browser_console
      page.driver.browser.logs.get(:browser).map { "#{Time.at(it.timestamp / 1000.0).utc.iso8601(3)} #{it.level} #{it.message}\n" }.join
    rescue Selenium::WebDriver::Error::WebDriverError => error
      "The browser gave no console log: #{error.class}: #{error.message.lines.first}"
    end

    # Quitting asks the hung browser to close, which times out too, though by
    # then Capybara has dropped it and stopped its driver. The second quit,
    # with no browser left to ask, clears the session.
    def quit_browser
      Capybara.current_session.quit
    rescue Net::ReadTimeout
      Capybara.current_session.quit
    end
end
