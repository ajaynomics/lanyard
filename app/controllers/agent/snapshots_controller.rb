module Agent
  # The whole current state, every time. The page replaces what it shows with
  # this rather than applying increments, so a reconnect cannot duplicate or
  # lose a message.
  class SnapshotsController < BaseController
    def show
      @conversation = conversation
      @snapshot = @conversation.snapshot(@access)
      respond_to do |format|
        format.turbo_stream
        format.json { render json: @snapshot }
      end
    end
  end
end
