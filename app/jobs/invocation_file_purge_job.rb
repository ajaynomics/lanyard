# What a call held for the sidecar (Invocation#held_files), gone once the
# sidecar may no longer fetch it (Invocation::FILE_WITHIN).
class InvocationFilePurgeJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(invocation) = invocation.held_files.purge
end
