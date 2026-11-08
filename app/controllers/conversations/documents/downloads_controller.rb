# The document as a file, its source exactly, named for its kind.
class Conversations::Documents::DownloadsController < ApplicationController
  include DocumentScoped

  def show
    send_data @document.body, filename: @document.filename, type: "#{@document.content_type}; charset=utf-8", disposition: "attachment"
  end
end
