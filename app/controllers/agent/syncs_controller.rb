module Agent
  # The sidecar committed entries; pull them soon. The pull, not this ping,
  # decides what is new, so a lost ping heals at the next one.
  class SyncsController < PrivateController
    def create
      ConversationSyncJob.perform_later(conversation)
      head :accepted
    end
  end
end
