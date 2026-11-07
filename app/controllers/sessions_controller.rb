# Ajent authenticates; this controller turns a verified identity into a
# session, for the addresses the app admits. If Ajent cannot be reached, nobody
# is let in.
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create failure ]
  # Open to the internet: each answer costs a call to Ajent or a page.
  rate_limit to: 10, within: 3.minutes, only: :create, name: "callback"
  rate_limit to: 30, within: 1.minute, only: %i[ new failure ], name: "pages"

  before_action only: %i[ create failure ] do
    response.set_header("Referrer-Policy", "no-referrer")
  end

  def new
    redirect_to root_path if session[:user_id]
  end

  def create
    auth = request.env["omniauth.auth"]
    claims = auth&.dig("extra", "raw_info") || {}
    email = (claims["email"].presence || auth&.dig("info", "email")).to_s.downcase
    # The strategy has verified the token, issuer included, before we get here.
    unless auth&.uid.present? && claims["email_verified"] == true && Admission.admits?(email)
      reset_session
      return redirect_to sign_in_path, alert: NOT_ADMITTED # turbo-ok: GET callback
    end

    start_session_for User.sign_in!(sub: auth.uid, email: email, name: claims["name"].presence || auth.dig("info", "name"))
  end

  def destroy
    reset_session
    redirect_to sign_in_path, status: :see_other
  end

  # OmniAuth lands here for every failure. config/initializers/omniauth.rb marks
  # the ones where Ajent could not be reached or answered with a server error:
  # a different thing to tell someone from a refusal.
  def failure
    reset_session
    return render :unreachable, status: :service_unavailable if params[:message] == "unreachable"
    return head :too_many_requests if params[:message] == "too_many_requests"
    redirect_to sign_in_path, alert: "Sign-in did not complete." # turbo-ok: GET from OmniAuth
  end
end
