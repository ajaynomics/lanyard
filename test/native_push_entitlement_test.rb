require "test_helper"
require "open3"

# The push-signing check needs Apple's codesign and a real exported .ipa, so it
# is proved on the build Mac against real exports (ios/TESTFLIGHT.md). Here:
# the procedure checks the very .ipa it uploads, before uploading it, and the
# check refuses what it cannot read.
class NativePushEntitlementTest < ActiveSupport::TestCase
  CHECK = Rails.root.join("ios/bin/check-push-entitlement")

  test "the procedure exports an .ipa, checks that file, and only then uploads it" do
    procedure = Rails.root.join("ios/TESTFLIGHT.md").read[/xcodebuild -exportArchive.*?^```/m]
    export = procedure.index("xcodebuild -exportArchive")
    check = procedure.index('bin/check-push-entitlement "$IPA" || exit 1')
    upload = procedure.index('xcrun altool --upload-app --type ios --file "$IPA"')
    assert check && upload, procedure
    assert export < check && check < upload, "the check must sit between the export and the upload"
    assert_includes Rails.root.join("ios/ExportOptions-testflight.plist").read, "<string>export</string>",
      "an export with destination upload sends the .ipa before anything can check it"
  end

  # Every signed app and extension in the .ipa is read from its signature, as
  # Apple's codesign gives it (here a stand-in that prints each bundle's
  # entitlements file), printed for the receipt, and held to distribution
  # signing: the phone app must have production push; any other target with
  # push must have production too, and none may be debuggable.
  test "it reads and prints every signed target's entitlements, and refuses any with development push or debugging" do
    ok = { "LanyardPhone.app" => { "aps-environment" => "production", "get-task-allow" => "false" },
           "LanyardPhone.app/Watch/LanyardWatch.app" => { "get-task-allow" => "false" },
           "LanyardPhone.app/PlugIns/Notices.appex" => { "aps-environment" => "production", "get-task-allow" => "false" } }
    out, error, status = check_ipa(ok)
    assert status.success?, error
    %w[ LanyardPhone.app LanyardWatch.app Notices.appex ].each { assert_match(/^== .*#{Regexp.escape(it)}$/, out) }
    assert_match "aps-environment=production", out
    assert_match "Push signing passed for 3 signed targets", out

    { "LanyardPhone.app/Watch/LanyardWatch.app" => { "aps-environment" => "development", "get-task-allow" => "false" },
      "LanyardPhone.app/PlugIns/Notices.appex" => { "get-task-allow" => "true" },
      "LanyardPhone.app" => { "get-task-allow" => "false" } }.each do |target, entitlements|
      _out, error, status = check_ipa(ok.merge(target => entitlements))
      assert_equal 1, status.exitstatus, target
      assert_includes error, File.basename(target)
      assert_includes error, "Stop before uploading."
    end
  end

  test "it refuses a missing or unreadable .ipa, and wrong arguments" do
    Dir.mktmpdir do |folder|
      _out, error, status = Open3.capture3(CHECK.to_s, File.join(folder, "absent.ipa"))
      assert_equal 1, status.exitstatus
      assert_includes error, "No exported .ipa"

      File.write(broken = File.join(folder, "broken.ipa"), "not a zip")
      _out, error, status = Open3.capture3(CHECK.to_s, broken)
      assert_equal 1, status.exitstatus
      assert_includes error, "Cannot unpack"
    end

    _out, error, status = Open3.capture3(CHECK.to_s)
    assert_equal 1, status.exitstatus
    assert_includes error, "Usage: check-push-entitlement <exported .ipa>"
  end

  private
    # An .ipa of stand-in bundles, each with the entitlements its signature
    # holds, and stand-in codesign and plutil on PATH that read them.
    def check_ipa(targets)
      Dir.mktmpdir do |folder|
        targets.each do |path, entitlements|
          FileUtils.mkdir_p(bundle = File.join(folder, "Payload", path))
          File.write(File.join(bundle, "signed-entitlements"), entitlements.map { |key, value| "#{key}=#{value}\n" }.join)
        end
        bin = File.join(folder, "bin")
        FileUtils.mkdir_p(bin)
        File.write(File.join(bin, "codesign"), "#!/bin/sh\nfor last; do :; done\ncat \"$last/signed-entitlements\"\n")
        File.write(File.join(bin, "plutil"), "#!/bin/sh\n# plutil -extract KEY raw -o - FILE\ngrep \"^$2=\" \"$6\" | cut -d= -f2 | grep . || exit 1\n")
        File.chmod(0o755, File.join(bin, "codesign"), File.join(bin, "plutil"))
        ipa = File.join(folder, "Lanyard.ipa")
        system("cd #{folder.shellescape} && zip -qr #{ipa.shellescape} Payload", exception: true)
        Open3.capture3({ "PATH" => "#{bin}:#{ENV['PATH']}" }, CHECK.to_s, ipa)
      end
    end
end
