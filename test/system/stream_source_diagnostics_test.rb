require "application_system_test_case"

# turbo-rails waits after each visit for the page's stream sources to connect,
# and when one does not it said only "Item does not match the provided
# selector" (11 failures in CI), which cannot tell late from never. The
# failure now names each source and says how it and its cable stand.
class StreamSourceDiagnosticsTest < ApplicationSystemTestCase
  test "a stream source that never connects is named, with its stream, its subscription and its cable" do
    visit sign_in_path # no one is signed in, so the cable is refused and nothing subscribes
    page.execute_script(<<~JS, Turbo::StreamsChannel.signed_stream_name("never-connects"))
      const source = document.createElement("turbo-cable-stream-source")
      source.setAttribute("channel", "Turbo::StreamsChannel")
      source.setAttribute("signed-stream-name", arguments[0])
      document.body.append(source)
    JS

    error = Capybara.using_wait_time(1) do
      assert_raises(Capybara::ExpectationNotMet) { connect_turbo_cable_stream_sources }
    end

    assert_match "Item does not match the provided selector", error.message
    assert_match %r{^- not connected: Turbo::StreamsChannel "never-connects", subscription \w[\w ]+, cable \w+$}, error.message
    assert_match(/Stream sources after waiting \d+\.\ds, \d+\.\ds into the page:/, error.message)
  end
end
