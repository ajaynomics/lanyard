require "test_helper"
require "open3"
require "fileutils"
require "tmpdir"

# bin/retry-system-tests run for real against a stub bin/rails that replays
# scripted output, so each case sees the script's own decisions: what it
# reruns, what it prints, and the exit status CI gets.
class RetrySystemTestsTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/retry-system-tests")

  setup do
    @sandbox = Dir.mktmpdir("retry-system-tests")
    FileUtils.mkdir_p(File.join(@sandbox, "bin"))
    File.write(File.join(@sandbox, "bin/rails"), <<~SH)
      #!/usr/bin/env bash
      # Call N prints out.N and exits with code.N.
      echo "$*" >> calls.log
      n=$(wc -l < calls.log | tr -d ' ')
      cat "out.$n"
      exit "$(cat "code.$n")"
    SH
    FileUtils.chmod(0o755, File.join(@sandbox, "bin/rails"))
  end

  teardown do
    FileUtils.remove_entry(@sandbox)
  end

  test "a passing suite runs once" do
    script [ "2 runs, 0 failures", 0 ]

    output, status = retry_system_tests

    assert status.success?, output
    assert_equal [ "test:system" ], calls
    assert_no_match(/FLAKY/, output)
  end

  test "a system test that fails then passes is retried once and CI passes" do
    script [ failure("test/system/settings_test.rb:12"), 1 ], [ "1 runs, 0 failures", 0 ]

    output, status = retry_system_tests

    assert status.success?, output
    assert_equal [ "test:system", "test test/system/settings_test.rb:12" ], calls
    assert_includes output, "FLAKY: test/system/settings_test.rb:12"
    assert_includes output, "Expected the page to show Saved", "the first failure stays in the log"
  end

  test "a system test that fails twice fails CI" do
    script [ failure("test/system/settings_test.rb:12"), 1 ], [ failure("test/system/settings_test.rb:12"), 1 ]

    output, status = retry_system_tests

    assert_not status.success?, output
    assert_equal 2, calls.size, "retried once, never twice"
    assert_includes output, "FLAKY: test/system/settings_test.rb:12"
  end

  test "a failure outside test/system is never retried" do
    script [ failure("test/system/settings_test.rb:12") + failure("test/models/agent_test.rb:7"), 1 ]

    output, status = retry_system_tests

    assert_not status.success?, output
    assert_equal [ "test:system" ], calls
    assert_no_match(/FLAKY/, output)
  end

  test "a run that fails without naming a test is not retried" do
    script [ "Could not load the database", 1 ]

    output, status = retry_system_tests

    assert_not status.success?, output
    assert_equal [ "test:system" ], calls
  end

  test "a run still going after its minutes is stopped, says so and fails CI" do
    File.write(File.join(@sandbox, "bin/rails"), <<~SH)
      #!/usr/bin/env bash
      printf '....'
      exec sleep 60
    SH

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    output, status = retry_system_tests("--minutes", "0.02")

    assert_not status.success?, output
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 30
    assert_includes output, "....", "what it printed before it hung stays in the log"
    assert_includes output, "Stopped after 0.02 minutes"
  end

  private
    def failure(location)
      "Failure:\nExpected the page to show Saved\n\nbin/rails test #{location}\n\n"
    end

    def script(*runs)
      runs.each.with_index(1) do |(out, code), n|
        File.write(File.join(@sandbox, "out.#{n}"), out)
        File.write(File.join(@sandbox, "code.#{n}"), code.to_s)
      end
    end

    def retry_system_tests(*options)
      output, status = Open3.capture2e(SCRIPT.to_s, *options, "bin/rails", "test:system", chdir: @sandbox)
      [ output, status ]
    end

    def calls
      File.readlines(File.join(@sandbox, "calls.log"), chomp: true)
    end
end
