module Agent
  # One answer to one pending question or approval. The sidecar holds the
  # authoritative answer record; a repeated identical answer returns it again,
  # and a different one is refused there.
  class AnswersController < BaseController
    def create
      answer = request.request_parameters["answer"]
      raise ActionController::BadRequest unless answer.is_a?(Hash)
      result = client.answer(@access, conversation.durable_id, params[:input_id], normalize(answer.to_h))
      respond_to do |format|
        format.html { back_to_conversation }
        format.json { render json: result }
      end
    end

    private
      # HTML checkbox groups arrive indexed by question; the native protocol
      # takes one array of selected values per question, in order.
      def normalize(answer)
        answer = answer.deep_dup
        if answer["selections"].is_a?(Hash)
          indexed = answer["selections"]
          raise ActionController::BadRequest unless indexed.keys.all? { |key| key.match?(/\A\d{1,2}\z/) }
          answer["selections"] = indexed.sort_by { |key, _| key.to_i }.map { |_, values| Array(values).compact_blank }
        end
        answer.delete("text") if answer.key?("text") && answer["text"].blank?
        answer
      end
  end
end
