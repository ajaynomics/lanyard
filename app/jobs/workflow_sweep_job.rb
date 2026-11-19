# Every minute (config/recurring.yml), deliberately global: every workflow run
# not yet settled is moved on (Workflow::Run#advance) in its own job, one at a
# time for a run, so one whose job was lost to a restart, or whose sidecar was
# down, still starts its steps and tells the agent how it ended.
class WorkflowSweepJob < ApplicationJob
  def perform
    Workflow::Run.unsettled.find_each { WorkflowRunJob.perform_later(it) } # tenancy-ok: the recurring sweep covers every unsettled run
  end
end
