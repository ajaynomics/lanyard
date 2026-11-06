module Agent
  # An explicit, authorised cancellation. Closing the page only stops watching.
  class CancellationsController < BaseController
    def create
      result = client.cancel(@access, conversation.durable_id, request_id)
      respond_to do |format|
        format.html { back_to_conversation }
        format.json { render json: result }
      end
    end
  end
end
