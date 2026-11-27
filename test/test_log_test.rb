require "test_helper"

# In CI a stalled write to log/test.log, on the disk the jobs contend for, held
# the browser tests' server and its cable for seconds (CI 10357, 10390, 10405).
# There the log is written to memory instead; the file this process has open
# says where it really goes.
class TestLogTest < ActiveSupport::TestCase
  test "in CI the test log is written to /dev/shm, off the disk" do
    skip "only CI keeps the log in /dev/shm" unless ENV["CI"].present? && File.writable?("/dev/shm")

    open_logs = Dir["/proc/self/fd/*"].filter_map { File.readlink(it) rescue nil }.grep(%r{/test\.log\z})
    assert_equal [ "/dev/shm" ], open_logs.map { File.dirname(it) }.uniq
  end
end
