# Settings, Apple Watch: the Watches with a token of their own (Watch), each
# revoked at /watches/:id, or, with none, how one connects.
class Settings::WatchesController < ApplicationController
  layout "settings"

  def index
    @watches = Current.user.watches.active.order(:created_at)
  end
end
