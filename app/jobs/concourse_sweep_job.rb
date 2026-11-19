# Every minute (config/recurring.yml) with no argument: deliberately global,
# it fans out one sweep per agent on Concourse, whoever owns it. With one
# (a ConcourseAgent), it reads that agent's mail (ConcourseAgent#sweep). It also starts a
# listener (ConcourseListenJob) for any connected agent that has none. The sweep is the queue
# fallback; the event log only makes mail sooner. A declined or disconnected
# agent is final until it joins again, and its sweep did nothing, so it gets
# none: each was a job a minute on the shared threads (#238). One Concourse
# rings for is read every five minutes instead (ConcourseAgent#sweep_due?).
class ConcourseSweepJob < ApplicationJob
  limits_concurrency key: ->(concourse_agent = nil) { concourse_agent || "all" }
  discard_on ActiveJob::DeserializationError # taken off Concourse meanwhile

  def perform(concourse_agent = nil)
    if concourse_agent
      concourse_agent.sweep
    elsif DurableAssistants::Concourse.configured?
      ConcourseAgent.joined.find_each do |concourse_agent| # tenancy-ok: the recurring sweep covers every agent on Concourse
        ConcourseSweepJob.perform_later(concourse_agent) if concourse_agent.sweep_due?
        # Discarded while one is listening, so only a missing listener starts;
        # none for an agent Concourse rings for.
        ConcourseListenJob.perform_later(concourse_agent) if concourse_agent.connected? && !concourse_agent.pushed?
      end
    end
  end
end
