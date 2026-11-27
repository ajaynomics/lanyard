require "application_system_test_case"

# A form's POST passes through the browser's HTTP cache, in its profile, before
# it is sent. In CI the default place for that profile, /tmp, is on the disk the
# jobs contend for, and a stall there held forms busy past every wait (CI 10253,
# 10256, 10265). Where /dev/shm has room, the profile is kept there.
class BrowserProfileTest < ApplicationSystemTestCase
  test "where /dev/shm has room, the browser keeps its profile there, off the disk" do
    skip "/dev/shm has no room for it" if ChromeSharedMemory.size < ChromeSharedMemory::ENOUGH

    assert_equal "/dev/shm", File.dirname(page.driver.browser.capabilities.as_json.dig("chrome", "userDataDir").to_s)
  end
end
