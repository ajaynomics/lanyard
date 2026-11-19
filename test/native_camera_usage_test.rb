require "test_helper"
require "open3"

# A file field in the phone app's web view offers Take Photo, and Take Photo
# runs the camera inside the app's own process. iOS kills an app that touches
# the camera without NSCameraUsageDescription, or records sound without
# NSMicrophoneUsageDescription. A field that takes more than pictures offers
# video too, which needs the microphone. Only a real phone shows the camera,
# so this reads what the Info.plist is generated from: each XcodeGen spec,
# with its includes merged as XcodeGen merges them.
class NativeCameraUsageTest < ActiveSupport::TestCase
  SPECS = %w[ ios/project.yml ios/project.testflight.yml ]

  FILE_FIELDS = Rails.root.glob("app/views/**/*.erb").flat_map do |view|
    view.read.scan(/file_field\b.*?%>|<input\b[^>]*\btype=["']file["'][^>]*>/m).map { [ view.relative_path_from(Rails.root).to_s, it ] }
  end

  test "the views have the file fields this test is about" do
    assert FILE_FIELDS.any? { |view, _| view == "app/views/conversations/_composer.html.erb" }, "the composer's attach field"
  end

  SPECS.each do |spec|
    test "#{spec}: the phone app may use the camera, and the microphone when a field takes video" do
      properties = phone_properties(spec)

      assert properties["NSCameraUsageDescription"].present?,
        "#{FILE_FIELDS.map(&:first).uniq.to_sentence} offer Take Photo: the phone's Info.plist needs NSCameraUsageDescription"

      if (videos = FILE_FIELDS.reject { |_, field| pictures_only?(field) }).any?
        assert properties["NSMicrophoneUsageDescription"].present?,
          "#{videos.map(&:first).uniq.to_sentence} take more than pictures, so offer video: the phone's Info.plist needs NSMicrophoneUsageDescription"
      end
    end
  end

  # The specs say what the Info.plist should hold; the upload is held to what
  # the signed app's Info.plist does hold, read from the .ipa that is uploaded,
  # as its push signing is (native_push_entitlement_test.rb).
  CHECK = Rails.root.join("ios/bin/check-usage-strings")

  test "the procedure checks the exported .ipa's usage strings before it uploads it" do
    procedure = Rails.root.join("ios/TESTFLIGHT.md").read[/xcodebuild -exportArchive.*?^```/m]
    export = procedure.index("xcodebuild -exportArchive")
    check = procedure.index('bin/check-usage-strings "$IPA" || exit 1')
    upload = procedure.index('xcrun altool --upload-app --type ios --file "$IPA"')
    assert check && upload, procedure
    assert export < check && check < upload, "the check must sit between the export and the upload"
  end

  test "it passes the signed phone app only with both usage strings, and says which is missing" do
    both = { "NSCameraUsageDescription" => "Take a photo.", "NSMicrophoneUsageDescription" => "Record a video." }
    out, error, status = check_ipa(both)
    assert status.success?, error
    assert_match "NSCameraUsageDescription=Take a photo.", out
    assert_match "Usage strings passed", out

    [ {}, both.except("NSMicrophoneUsageDescription"), both.merge("NSCameraUsageDescription" => "") ].each do |plist|
      _out, error, status = check_ipa(plist)
      assert_equal 1, status.exitstatus, plist.inspect
      assert_includes error, "LanyardPhone.app"
      assert_includes error, (both.keys - plist.select { |_, value| value.present? }.keys).first
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
    assert_includes error, "Usage: check-usage-strings <exported .ipa>"
  end

  private
    # An .ipa whose phone app's Info.plist holds these keys, and a stand-in
    # plutil on PATH that reads them as Apple's would, printing an empty
    # string as empty.
    def check_ipa(plist)
      Dir.mktmpdir do |folder|
        FileUtils.mkdir_p(app = File.join(folder, "Payload", "LanyardPhone.app"))
        File.write(File.join(app, "Info.plist"), plist.map { |key, value| "#{key}=#{value}\n" }.join)
        FileUtils.mkdir_p(bin = File.join(folder, "bin"))
        File.write(File.join(bin, "plutil"), "#!/bin/sh\n# plutil -extract KEY raw -o - FILE\ngrep -q \"^$2=\" \"$6\" || exit 1\ngrep \"^$2=\" \"$6\" | cut -d= -f2-\n")
        File.chmod(0o755, File.join(bin, "plutil"))
        ipa = File.join(folder, "Lanyard.ipa")
        system("cd #{folder.shellescape} && zip -qr #{ipa.shellescape} Payload", exception: true)
        Open3.capture3({ "PATH" => "#{bin}:#{ENV['PATH']}" }, CHECK.to_s, ipa)
      end
    end

    def phone_properties(spec)
      load_spec(Rails.root.join(spec)).dig("targets", "LanyardPhone", "info", "properties").to_h
    end

    # XcodeGen's includes (ProjectSpec.md, "Include"): the including spec
    # merges over each included one; dictionaries merge, arrays append, and a
    # key ending in :REPLACE replaces. An optional include counts as on, so a
    # build with it can't lose a key.
    def load_spec(path)
      spec = YAML.load_file(path)
      Array(spec.delete("include")).reduce({}) do |merged, included|
        merge(merged, load_spec(path.dirname.join(included.is_a?(Hash) ? included["path"] : included)))
      end.then { merge(it, spec) }
    end

    def merge(base, over)
      over.each_with_object(base.dup) do |(key, value), merged|
        if key.end_with?(":REPLACE")
          merged[key.delete_suffix(":REPLACE")] = value
        elsif merged[key].is_a?(Hash) && value.is_a?(Hash)
          merged[key] = merge(merged[key], value)
        elsif merged[key].is_a?(Array) && value.is_a?(Array)
          merged[key] = merged[key] + value
        else
          merged[key] = value
        end
      end
    end

    def pictures_only?(field)
      accept = field[/accept(?::\s*|=)["']([^"']*)["']/, 1]
      accept.present? && accept.split(",").map(&:strip).all? { it.start_with?("image/") }
    end
end
