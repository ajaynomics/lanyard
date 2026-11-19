require "test_helper"

# The phone app's tabs, its sheets' close buttons and its tab badge were fixed
# in Swift (REVIEW.md findings 14, 16 and 17): renaming a tab needed a new
# build, the close button repeated the path rules' own paths, and the badge
# went through a notification posted to the whole app. Rails now says the
# first two (PathConfiguration) and the page's own component sets the third.
# The Swift is compiled only on the build Mac, so this reads the source; the
# build Mac's AppTabTests decode what Rails serves.
class NativeTabsTest < ActiveSupport::TestCase
  def swift(path) = Rails.root.join("ios/Phone", path).read

  test "the app's tabs are the ones Rails serves, its own list only the fallback" do
    assert_match(/settings\[\s*"tabs"\s*\]/, swift("AppTab.swift"), "AppTab decodes the path configuration's tabs")
    assert_no_match(/enum AppTab\b/, swift("AppTab.swift"), "no tab is fixed as a case of an enum")
    assert_match(/AppTab\.served\(/, swift("SceneController.swift"), "the tabs are built from what Rails serves")
  end

  test "a sheet's close button is the path rules' word, not a path matched in Swift" do
    assert_match(/"close"/, swift("SheetClose.swift"))
    assert_no_match(/hasSuffix|"\/sign_in"/, swift("SheetClose.swift"))
  end

  test "the badge is set by its component on the tabs it is in, not posted to the whole app" do
    assert_no_match(/NotificationCenter\.default/, swift("Bridge/TabBadgeComponent.swift"))
    # The scene still hears a sign-out from Settings that way (SessionComponent.signedOut), but not the badge.
    assert_no_match(/TabBadgeComponent\.changed/, swift("SceneController.swift"))
    assert_match(/destination/, swift("Bridge/TabBadgeComponent.swift"), "the component finds the tabs from its own page")
  end
end
