# The phone, signed in, asks for a token for its Watch and hands it over
# (Watch); its own web session and Rails' forgery check guard the asking, as
# for any change. Revoke, in Settings (Apple Watch), refuses that token at once.
class WatchesController < ApplicationController
  def create
    watch = Current.user.watches.create!(name: params[:name])
    render json: { id: watch.id, token: watch.token }, status: :created
  end

  def destroy
    Current.user.watches.active.find(params[:id]).revoke!
    saved settings_watches_path
  end
end
