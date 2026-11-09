# Fetches what an approval card shows (Invocation#fetch_preview) away from the
# sidecar's request and outside any transaction, then redraws the card.
class InvocationPreviewJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(invocation) = invocation.fetch_preview
end
