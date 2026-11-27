# A one-time link to a conversation's screen, opened by someone not signed in
# here (ScreenPass): the page, the websocket it opens at the same address, and
# the visitor's Done. Open to the internet, so rate limited
# (docs/open-routes.md); the link's token is the whole claim, and the first
# device to open it keeps it, by a key in an encrypted cookie.
class ScreenPassesController < ApplicationController
  include ScreenRelay

  allow_unauthenticated_access
  rate_limit to: 30, within: 1.minute, name: "screen_passes"
  # The link's address goes to no other site. Not no-referrer: from such a
  # page a browser posts its form with Origin "null", and Rails refuses Done.
  before_action { response.set_header("Referrer-Policy", "same-origin") }
  before_action :set_pass

  def show
    if websocket?
      return head :not_found unless @pass.live? && @pass.viewer?(viewer_key)
      return head :service_unavailable if held?
      return head :forbidden unless request.origin == app_origin
      return open_screen(@conversation) { @pass.reload.live? }
    end

    return over(@pass.why_over) unless @pass.live?
    unless @pass.viewer?(viewer_key)
      key = @pass.open! or return over(:elsewhere)
      cookies.encrypted[cookie_name] = { value: key, expires: @pass.expires_at, httponly: true, same_site: :strict, secure: request.ssl? }
    end
    @held = held?
    @waking_from_cold = @conversation.waking_from_cold? unless @held
  end

  def destroy
    return head :not_found unless @pass.viewer?(viewer_key)
    @pass.end!
    cookies.delete(cookie_name)
  end

  private
    def set_pass
      @pass = ScreenPass.find_by_token(params[:token]) or raise ActiveRecord::RecordNotFound # tenancy-ok: the token is the visitor's whole claim, to one pass
      @conversation = @pass.conversation
    end

    def held? = @conversation.agent.computer&.held? || !@conversation.shareable_screen?

    def cookie_name = "screen_pass_#{@pass.id}"

    def viewer_key = cookies.encrypted[cookie_name]

    def over(why)
      @why = why
      render :over, status: :gone
    end
end
