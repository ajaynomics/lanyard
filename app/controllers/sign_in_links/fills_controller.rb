# The one submit of a link for someone outside (SignInLink#fill): what was
# typed goes from this request to the vault, inside it, so it is never in a
# job's arguments, a row, the log or the thread. The link is used up before
# the write; a failed write says so and can't be tried again through it.
class SignInLinks::FillsController < ApplicationController
  # Counted before the link is looked up, so unknown tokens count too.
  rate_limit to: 10, within: 1.minute, name: "sign_in_link_fills"
  include SignInLinkVisited
  # A page that sends no referrer posts its form with Origin "null", which
  # Rails' origin check refuses outright. Its check of the browser's own
  # Sec-Fetch-Site still turns away a post from another site.
  self.forgery_protection_origin_check = false

  def create
    return refused unless @link.open?
    fields = params.expect(sign_in: %i[ username password account ])
    if fields.values_at(:username, :password).any?(&:blank?)
      @alert = "Type the username and password."
      return render "sign_in_links/show", status: :unprocessable_entity
    end

    case @link.fill(username: fields[:username], password: fields[:password], account: fields[:account])
    when "filled" then render :filled
    when "failed" then render :failed, status: :bad_gateway
    else refused
    end
  end
end
