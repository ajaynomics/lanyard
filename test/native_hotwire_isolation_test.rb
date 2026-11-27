require "test_helper"

# Hotwire Native's NavigatorDelegate and ErrorPresentableView predate Swift
# concurrency: their requirements are nonisolated. The phone's SceneController
# and ErrorScreen are main-actor types, so a plain conformance only warned
# ("cannot satisfy nonisolated requirement") and promised nothing. Conformed
# `@preconcurrency`, Swift checks at run time that Hotwire Native calls them on
# the main actor, which it does: WebKit's callbacks arrive there. The Swift is
# compiled only on the build Mac, so this reads the source.
class NativeHotwireIsolationTest < ActiveSupport::TestCase
  SOURCES = Rails.root.glob("ios/Phone/**/*.swift").to_h { [ it.relative_path_from(Rails.root).to_s, it.read ] }
  PRECONCURRENCY_PROTOCOLS = %w[ NavigatorDelegate ErrorPresentableView ]

  test "the phone's conformances to Hotwire Native's nonisolated protocols are @preconcurrency" do
    PRECONCURRENCY_PROTOCOLS.each do |protocol|
      conformances = SOURCES.flat_map do |path, swift|
        swift.scan(/^[ \t]*(?:[@\w]+[ \t]+)*(?:extension|class|struct)[ \t]+\w+[ \t]*:([^{]*\b#{protocol}\b[^{]*)\{/).map { |(list)| [ path, list ] }
      end
      assert_not_empty conformances, "the phone conforms to #{protocol}"
      conformances.each do |path, list|
        assert_match(/@preconcurrency[ \t]+#{protocol}\b/, list, "#{path}: #{protocol} is nonisolated, so a main-actor type conforms @preconcurrency")
      end
    end
  end
end
