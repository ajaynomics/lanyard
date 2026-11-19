# Fetches what an approval card shows (Invocation#fetch_preview) away from the
# sidecar's request and outside any transaction, then redraws the card. On
# the calls queue (config/queue.yml): until it runs, a person looking at the
# card cannot allow it.
class InvocationPreviewJob < ApplicationJob
  queue_as :calls
  discard_on ActiveJob::DeserializationError

  def perform(invocation) = invocation.fetch_preview
end
