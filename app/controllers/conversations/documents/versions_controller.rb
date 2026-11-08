# A document's history, newest first, for the canvas's History.
class Conversations::Documents::VersionsController < ApplicationController
  include DocumentScoped

  def index
    @versions = @document.versions.reorder(number: :desc)
  end
end
