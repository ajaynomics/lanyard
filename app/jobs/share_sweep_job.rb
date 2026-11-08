# Every hour (config/recurring.yml), deliberately global: a share nobody sent
# within a day goes, pictures and all, whoever it was for. A share that is
# sent goes at once (SubmissionsController); this is for the rest.
class ShareSweepJob < ApplicationJob
  def perform
    Share.where(created_at: ...Share::KEEP.ago).find_each(&:destroy) # tenancy-ok: the sweep clears every person's unsent shares
  end
end
