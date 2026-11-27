require "test_helper"
require "fileutils"
require "open3"
require "tmpdir"

class NativeBridgeGeneratorTest < ActiveSupport::TestCase
  test "an explicitly requested missing Pro manifest stops before generation" do
    in_copy do |script, env, root|
      output, status = Open3.capture2e(env.merge("BRIDGE_COMPONENTS_PRO_PATH" => "#{root}/missing-pro"), script.to_s)

      assert_not status.success?
      assert_match "Package.swift", output
      assert_not_includes output, "GENERATOR RAN"
    end
  end

  test "an unset Pro path leaves the public generator and its arguments alone" do
    in_copy do |script, env, _root|
      output, status = Open3.capture2e(env, script.to_s, "--spec", "project.yml")

      assert status.success?, output
      assert_includes output, "GENERATOR RAN false generate --spec project.yml"
    end
  end

  test "a Pro manifest is passed through to the generator" do
    in_copy do |script, env, root|
      manifest = root.join("fixture-pro/Package.swift")
      FileUtils.mkdir_p(manifest.dirname)
      File.write(manifest, "// Test fixture, not a licensed package")

      output, status = Open3.capture2e(env.merge("BRIDGE_COMPONENTS_PRO_PATH" => manifest.dirname.to_s), script.to_s)

      assert status.success?, output
      assert_includes output, "GENERATOR RAN true"
    end
  end

  test "a changed Swift package pin stops before generation" do
    in_copy do |script, env, root|
      spec = root.join("checkout/ios/project.yml")
      spec.write(spec.read.sub("exactVersion: 0.14.0", "exactVersion: 0.14.1"))
      output, status = Open3.capture2e(env, script.to_s)

      assert_not status.success?
      assert_match "Swift 0.14.0", output
      assert_not_includes output, "GENERATOR RAN"
    end
  end

  test "a changed vendored JavaScript version stops before generation" do
    in_copy do |script, env, root|
      vendor = root.join("checkout/vendor/javascript/@joemasilotti--bridge-components.js")
      vendor.write(vendor.read.sub("bridge-components@0.13.2", "bridge-components@0.14.0"))
      output, status = Open3.capture2e(env, script.to_s)

      assert_not status.success?
      assert_match "JavaScript 0.13.2", output
      assert_not_includes output, "GENERATOR RAN"
    end
  end

  private
    def in_copy
      Dir.mktmpdir do |folder|
        root = Pathname.new(folder)
        bin = root.join("checkout/ios/bin")
        FileUtils.mkdir_p(bin)
        script = bin.join("generate")
        FileUtils.copy_file(Rails.root.join("ios/bin/generate"), script)
        File.chmod(0o700, script)
        %w[ ios/project.yml config/importmap.rb vendor/javascript/@joemasilotti--bridge-components.js ].each do |path|
          copy = root.join("checkout", path)
          FileUtils.mkdir_p(copy.dirname)
          FileUtils.copy_file(Rails.root.join(path), copy)
        end
        fake = bin.join("xcodegen")
        File.write(fake, "#!/bin/sh\nprintf 'GENERATOR RAN %s %s\\n' \"$BRIDGE_COMPONENTS_PRO\" \"$*\"\n")
        File.chmod(0o700, fake)
        yield script, { "PATH" => "#{bin}:/usr/bin:/bin", "BRIDGE_COMPONENTS_PRO_PATH" => nil }, root
      end
    end
end
