# Every hour (config/recurring.yml), deliberately global: files read for a
# call that never used them (refused, declined, or never arrived) go once no
# call could still be waiting for them. A call that sends its files clears
# them at once (Tool::SendEmail); this is for the rest.
class UploadSweepJob < ApplicationJob
  def perform
    Upload.where(created_at: ...Upload::KEEP.ago).find_each(&:destroy) # tenancy-ok: the sweep clears every person's unused uploads
  end
end
