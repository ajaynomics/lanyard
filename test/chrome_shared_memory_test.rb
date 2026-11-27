require "test_helper"
require_relative "test_helpers/chrome_shared_memory"

# The browser tests' Chrome keeps its shared memory in /tmp, on disk, only
# where /dev/shm is too small to hold it.
class ChromeSharedMemoryTest < ActiveSupport::TestCase
  MB = 1024 * 1024

  test "under 512 MB of /dev/shm, Chrome is told to keep its shared memory in /tmp; at 512 MB or more, nothing is added" do
    assert_equal [ "--disable-dev-shm-usage" ], ChromeSharedMemory.arguments(64 * MB)
    assert_equal [ "--disable-dev-shm-usage" ], ChromeSharedMemory.arguments(512 * MB - 1)
    assert_equal [], ChromeSharedMemory.arguments(512 * MB)
    assert_equal [], ChromeSharedMemory.arguments(1024 * MB)
  end

  test "/dev/shm has room for Chrome's profiles from 512 MB" do
    assert_not ChromeSharedMemory.room?(512 * MB - 1)
    assert ChromeSharedMemory.room?(512 * MB)
  end

  test "a /dev/shm whose size can't be read counts as too small, as before" do
    assert_equal 0, ChromeSharedMemory.size("/nonexistent/shm")
    assert_equal [ "--disable-dev-shm-usage" ], ChromeSharedMemory.arguments(ChromeSharedMemory.size("/nonexistent/shm"))
  end
end
