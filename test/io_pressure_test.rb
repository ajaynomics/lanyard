require "test_helper"
require "open3"
require "tmpdir"

# bin/io-pressure run for real against a written pressure file, as CI runs it
# against /proc/pressure/io around the system tests.
class IoPressureTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("bin/io-pressure").to_s

  def pressure(some:, full:)
    @dir ||= Dir.mktmpdir("io-pressure")
    File.join(@dir, "io").tap do |path|
      File.write(path, "some avg10=#{some[0]} avg60=#{some[1]} avg300=1.00 total=1\nfull avg10=#{full[0]} avg60=#{full[1]} avg300=1.00 total=1\n")
    end
  end

  teardown { FileUtils.remove_entry(@dir) if @dir }

  def run_script(*args)
    out, status = Open3.capture2e(SCRIPT, *args)
    [ out, status.exitstatus ]
  end

  test "a quiet disk is recorded, with no warning" do
    out, code = run_script("before system tests", pressure(some: [ 1.5, 2.25 ], full: [ 0.5, 1.0 ]))
    assert_equal "I/O pressure before system tests: some avg10=1.50 avg60=2.25, full avg10=0.50 avg60=1.00\n", out
    assert_equal 0, code
  end

  test "a busy disk warns, naming the level, and never fails the run" do
    [ { some: [ 31.7, 4.0 ], full: [ 0.0, 0.0 ] }, { some: [ 2.0, 10.0 ], full: [ 0.0, 0.0 ] },
      { some: [ 2.0, 2.0 ], full: [ 5.0, 0.0 ] }, { some: [ 2.0, 2.0 ], full: [ 0.0, 7.0 ] } ].each do |levels|
      out, code = run_script("after system tests", pressure(**levels))
      assert_match(/\A::warning::I\/O pressure after system tests is high: some avg10=.* full avg10=.*\(warns at some 10, full 5\); a browser test failing now may be the disk, not the code\n\z/, out, levels.inspect)
      assert_equal 0, code
    end
  end

  test "a pressure file it can't read or parse says so and never fails the run" do
    @dir ||= Dir.mktmpdir("io-pressure")
    some_only = File.join(@dir, "some-only").tap { File.write(it, "some avg10=1.00 avg60=2.00 avg300=1.00 total=1\n") }
    { some_only => "KeyError", "/nonexistent/io" => "Errno::ENOENT", @dir => "Errno::EISDIR" }.each do |path, error|
      out, code = run_script("before system tests", path)
      assert_equal "I/O pressure before system tests: not readable here (#{error})\n", out, path
      assert_equal 0, code, path
    end
  end
end
