# Ajent authenticates; this controller turns a verified identity into a
# session, for the addresses the app admits.
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create failure ]

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
    unless auth&.uid.present? && claims["email_verified"] == true && User.admitted?(email)
      reset_session
      return redirect_to sign_in_path, alert: "That account is not set up for Avery." # turbo-ok: GET callback
    end

    start_session_for User.sign_in_from_oidc!(sub: auth.uid, email: email, name: claims["name"].presence || auth.dig("info", "name"))
  end

  def destroy
    reset_session
    redirect_to sign_in_path, status: :see_other
  end

  def failure
    reset_session
    redirect_to sign_in_path, alert: "Sign-in did not complete." # turbo-ok: GET from OmniAuth
  end
end
