require "test_helper"
require "yaml"

class NativeDisplayNameTest < ActiveSupport::TestCase
  test "the iPhone and Watch show Ajent without changing their project, products or bundle identities" do
    project = YAML.safe_load_file(Rails.root.join("ios/project.yml"))
    targets = project.fetch("targets")
    phone = targets.fetch("LanyardPhone")
    watch = targets.fetch("LanyardWatch")

    assert_equal "Ajent", phone.dig("info", "properties", "CFBundleDisplayName")
    assert_equal "Ajent", watch.dig("info", "properties", "CFBundleDisplayName")
    assert_equal "Lanyard", project.fetch("name")
    assert_equal "org.durableassistants.companion", project.dig("settings", "base", "PHONE_BUNDLE_ID")
    assert_equal "LanyardPhone", phone.dig("settings", "base", "PRODUCT_NAME")
    assert_equal "LanyardWatch", watch.dig("settings", "base", "PRODUCT_NAME")
    assert_equal "$(PHONE_BUNDLE_ID)", phone.dig("settings", "base", "PRODUCT_BUNDLE_IDENTIFIER")
    assert_equal "$(PHONE_BUNDLE_ID).watchkitapp", watch.dig("settings", "base", "PRODUCT_BUNDLE_IDENTIFIER")
    assert_equal "$(PHONE_BUNDLE_ID)", watch.dig("info", "properties", "WKCompanionAppBundleIdentifier")
  end
end
