require "test_helper"

# Tapping a notice killed the phone app (TestFlight). iOS may call a
# notification delegate on a queue of its own, not the main thread, and UIKit
# asserts that a tap's completion handler is called on the main thread. An
# `async` delegate method leaves it to Swift's bridging where that handler is
# called; a main-actor completion-handler method traps when iOS calls it from
# its own queue. So the phone's and the Watch's take iOS's completion handler,
# are nonisolated and call it from the main actor. The Swift is compiled only
# on the build Mac, so this reads the source.
class NativeNoticeIsolationTest < ActiveSupport::TestCase
  SOURCES = Rails.root.glob("ios/**/*.swift").to_h { [ it.relative_path_from(Rails.root).to_s, it.read ] }
  METHOD = /^(?<indent>[ \t]*)(?<modifiers>(?:[@\w]+(?:\([^)]*\))?[ \t]+)*)func[ \t]+userNotificationCenter\((?<signature>[^{]*)\{(?<body>.*?)^\k<indent>\}/m

  def delegate_methods
    SOURCES.flat_map do |path, swift|
      swift.to_enum(:scan, METHOD).map { Regexp.last_match }.map { [ path, it ] }
    end
  end

  test "no notification delegate method is a main-actor completion-handler method, or a nonisolated async one" do
    assert_operator delegate_methods.size, :>=, 4, "the phone's and the Watch's willPresent and didReceive"
    delegate_methods.each do |path, method|
      nonisolated = method[:modifiers].match?(/\bnonisolated\b/)
      async = method[:signature].match?(/\)\s*async\b/)
      if nonisolated
        assert_not async, "#{path}: a nonisolated async delegate method calls iOS's handler off the main thread"
      else
        assert async, "#{path}: a main-actor delegate method taking iOS's handler traps when iOS calls it off the main thread"
      end
    end
  end

  test "the phone's and the Watch's delegate methods call iOS's completion handler from the main actor" do
    %w[ ios/Phone/ ios/Watch/ ].each do |app|
      assert_equal 2, delegate_methods.count { |path, _| path.start_with?(app) }, "#{app}: willPresent and didReceive"
    end
    delegate_methods.each do |path, method|
      assert_match(/\bnonisolated\b/, method[:modifiers], path)
      assert_includes method[:signature], "withCompletionHandler completionHandler:", path
      assert_match(/Task\s*\{\s*@MainActor\s+in\b/, method[:body], "#{path}: finishes on the main actor")
      assert_match(/\bdone\.call\(\)/, method[:body], "#{path}: calls iOS's handler there")
      assert_no_match(/assumeIsolated/, method[:body], "#{path}: iOS's queue is not the main actor's")
    end
  end

  # A cold launch starts as if signed in (SessionGate), so a page opened as
  # the tabs appear could be refused, and the tap lost behind the sign-in.
  test "a tapped notice's page goes through the router, which holds it until a page of fresh tabs loads signed in" do
    scene = SOURCES.fetch("ios/Phone/SceneController.swift")
    assert scene.include?("PushRegistration.shared.router.ready"), "SceneController opens taps through the router"
    built = scene[/func showTabs\(.*?\{(.*?)^    \}/m, 1].to_s
    assert_includes built, "PushRegistration.shared.router.tabsBuilt()", "fresh tabs hold the tap until their first page"
    finished = scene[/func requestDidFinish\(at url: URL\) \{(.*?)^    \}/m, 1].to_s
    assert_match(/if gate\.phase == \.signedIn \{ PushRegistration\.shared\.router\.pageLoaded\(\) \}/, finished,
      "a page that loaded signed in lets the held tap open; a 401 has already started the wait")
    assert_no_match(/router\.routePending\(\)/, scene, "nothing opens the tap before a page has loaded")
    assert SOURCES.fetch("ios/Phone/PushRegistration.swift").include?("router.route(tap.url)"), "a tap's page goes to the router"
    assert Rails.root.join("ios/project.yml").read.include?("- Phone/NotificationRouter.swift"), "its tests build it"
  end

  test "every type that is a notification delegate is main-actor isolated" do
    delegates = SOURCES.flat_map do |path, swift|
      swift.scan(/^[ \t]*(?:[@\w]+[ \t]+)*(?:extension|class|struct|actor)[ \t]+(\w+)[^{]*?:[^{]*\bUNUserNotificationCenterDelegate\b/).map { |(name)| [ path, name ] }
    end
    assert_operator delegates.size, :>=, 2, "the phone's PushRegistration and the Watch's NoticeDesk"
    delegates.each do |path, name|
      declared = SOURCES.values.any? { it.match?(/@MainActor\s+(?:(?:final|public|internal|private|fileprivate|open)\s+)*class\s+#{name}\b/) }
      assert declared, "#{path}: #{name} is a notification delegate, so it must be @MainActor"
    end
  end
end
