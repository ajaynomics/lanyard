module Sidecar
  # The sidecar committed entries; pull them now. The sidecar waits for this
  # before its next frame, so a committed reply is on the page before the
  # live tail that showed it clears. The pull, not this ping, decides what is
  # new, so a lost ping heals at the next one; a failed pull is left to a job.
  class SyncsController < PrivateController
    def create
      conversation.pull
      head :no_content
    end
  end
end
