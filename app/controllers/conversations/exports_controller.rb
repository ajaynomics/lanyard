# A conversation's history as a file pi opens (`pi --session <file>`),
# streamed from the sidecar as it writes it: a history with pictures runs to
# megabytes, and none of it is kept here.
class Conversations::ExportsController < ApplicationController
  include ActionController::Live

  def show
    conversation = Current.user.conversations.find(params[:conversation_id])
    raise ActionController::UnknownFormat unless request.format.jsonl?

    # The headers go with the first chunk, so a sidecar that refuses is still
    # an error status rather than an empty download.
    conversation.export do |chunk|
      start_download(conversation) unless response.committed?
      response.stream.write(chunk)
    end
  ensure
    response.stream.close if response.committed?
  end

  private
    def start_download(conversation)
      response.headers["Content-Type"] = Mime[:jsonl].to_s
      response.headers["Content-Disposition"] = ActionDispatch::Http::ContentDisposition.format(disposition: "attachment",
        filename: "#{conversation.to_s.tr('/\\', '-').truncate(100, omission: '')}.jsonl")
      response.headers["Cache-Control"] = "no-store"
    end
end
