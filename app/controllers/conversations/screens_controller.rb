# The conversation's screen: a page that shows its Sprite's desktop through noVNC, and
# the websocket that page opens to this same address. Rails relays the
# websocket to the sidecar, which wakes the Sprite and pipes it to the
# screen's websockify (docs/design/CONTRACT.md). You watch and type while the
# conversation works. The page also makes one-time links to it (ScreenPass).
class Conversations::ScreensController < ApplicationController
  include ScreenRelay

  def show
    @conversation = find_in_workspace(:conversations, params[:conversation_id])
    @retained = @conversation.retained_browser_for?(Current.user)
    raise ActiveRecord::RecordNotFound unless @retained || @conversation.shareable_screen?
    # An operator is rebuilding its Sprite: opening the screen would make a fresh one.
    @held = @conversation.agent.computer.held?
    unless websocket?
      @waking_from_cold = @conversation.waking_from_cold? unless @held || @retained
      @passes = @conversation.screen_passes.live.order(:created_at)
      return
    end
    return head :service_unavailable if @held
    # A websocket carries the person's cookies from any page that opens it.
    return head :forbidden unless request.origin == app_origin

    return open_screen(@conversation) unless @retained

    person = Current.user
    open_screen(@conversation, retained: true) { @conversation.reload.retained_browser_for?(person) }
  end
end
