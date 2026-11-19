require "test_helper"

# A save through the real commands to a real, throwaway Passbolt, while a
# scanner reads every process's arguments and every environment it may: every
# account on the host can read /proc/<pid>/cmdline, so the new password must
# never be there. Opt in with `passbolt` (go-passbolt-cli, as the Dockerfile
# pins it) and `passbolt-save` (go build ./passbolt-save) on PATH, and a JSON
# file {"url", "private_key", "passphrase"} for a throwaway Passbolt user
# (go-passbolt-cli's internal/e2e/server starts passbolt/passbolt:5.14.3 with
# its MariaDB and makes one):
#
#   PASSBOLT_ARGV_TEST=tmp/server.json bin/rails test test/lib/passbolt_argv_test.rb
#
# Without it it skips, so bin/ci never needs Docker; test/lib/passbolt_test.rb
# holds that no argument carries a secret flag.
class PassboltArgvTest < ActiveSupport::TestCase
  setup do
    skip "set PASSBOLT_ARGV_TEST to a throwaway Passbolt user's file to run this" unless ENV["PASSBOLT_ARGV_TEST"]
    server = JSON.parse(File.read(ENV["PASSBOLT_ARGV_TEST"]))
    @previous = Rails.application.config.x.passbolt.dup
    Rails.application.config.x.passbolt.merge!(url: server["url"], private_key: server["private_key"], passphrase: server["passphrase"])
  end

  teardown { Rails.application.config.x.passbolt.replace(@previous) if @previous }

  test "a new password is never in any process's arguments while it is saved, and is saved" do
    marker = "pbmarker-#{SecureRandom.hex(8)}"
    scans, seen, done = 0, Set.new, false
    scanner = Thread.new do
      until done
        scans += 1
        Dir.glob("/proc/[0-9]*/{cmdline,environ}").each do |file|
          seen << file if File.binread(file).include?(marker)
        rescue SystemCallError
          next # gone, or another account's environment
        end
      end
    end
    begin
      saved = DurableAssistants::Passbolt.save(nil, name: "argv-test-#{SecureRandom.hex(4)}", address: "https://argv.example",
        username: "maya", password: marker)
    ensure
      done = true
      scanner.join
    end

    puts "scans=#{scans} files with the password=#{seen.size} #{seen.map { it.sub(/\d+/, "<pid>") }.uniq.join(" ")}"
    assert_empty seen, "the password was readable in another process's arguments or environment"
    assert_operator scans, :>, 1, "the scanner ran while the save did"
    assert_equal marker, DurableAssistants::Passbolt.sign_in(nil, saved.fetch("id")).password
  end
end
