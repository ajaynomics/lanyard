# Chrome keeps its shared memory in /dev/shm, or in /tmp when told
# --disable-dev-shm-usage. A CI container's /dev/shm was 64 MB, too small for
# Chrome, so the flag; but in CI /tmp is on the disk the jobs contend for. With
# room for Chrome in /dev/shm the flag is left off and that memory stays off the
# disk. A size that can't be read counts as too small, as before.
module ChromeSharedMemory
  ENOUGH = 512 * 1024 * 1024

  def self.arguments(bytes = size) = room?(bytes) ? [] : [ "--disable-dev-shm-usage" ]

  def self.room?(bytes = size) = bytes >= ENOUGH

  def self.size(path = "/dev/shm")
    IO.popen([ "df", "-Pk", path ], err: File::NULL, &:read).lines.drop(1).first.split[1].to_i * 1024
  rescue StandardError
    0
  end
end
