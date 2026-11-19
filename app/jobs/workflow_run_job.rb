# Moves a workflow's run on (Workflow::Run#advance): when it starts, when a
# step ends, and when a helper ends and makes room. One at a time for a run;
# a sidecar that can't be reached is asked again, and WorkflowSweepJob asks
# every minute after that.
class WorkflowRunJob < ApplicationJob
  limits_concurrency key: ->(run) { run }
  retry_on DurableAssistants::PiDurable::Client::Error, Conversation::Submission::Refused, wait: 5.seconds, attempts: 3
  discard_on ActiveJob::DeserializationError

  def perform(run)
    run.advance
  end
end
