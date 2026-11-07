# Every minute (config/recurring.yml) with no argument: deliberately global,
# it fans out one sweep per bot on Concourse, whoever owns it. With an agent,
# it reads that agent's mail (ConcourseAgent#sweep). The sweep is the queue
# fallback; a doorbell ping only makes it sooner (PARITY.md §28).
class ConcourseSweepJob < ApplicationJob
  limits_concurrency key: ->(concourse_agent = nil) { concourse_agent || "all" }
  discard_on ActiveJob::DeserializationError # taken off Concourse meanwhile

  def perform(concourse_agent = nil)
    if concourse_agent
      concourse_agent.sweep
    else
      ConcourseAgent.find_each { ConcourseSweepJob.perform_later(it) } # tenancy-ok: the recurring sweep covers every bot on Concourse
    end
  end
end
