# The phone app's sign-in (NativeSignIn). `new` opens in the app's browser
# sheet: it keeps the app's challenge in that browser's session and begins the
# ordinary sign-in, whose callback then hands the app a code instead of
# starting a session there (Authentication#complete_sign_in). `create` is the
# app trading that code and its verifier for a session in its own web view.
class NativeSignInsController < ApplicationController
  # How long the person has to sign in at the provider.
  PENDING_FOR = 10.minutes

  allow_unauthenticated_access
  # The app posts from its own web view, with no page of ours before it and so
  # no authenticity token. The code is bound to a verifier only the app holds,
  # which no other site can supply, so nobody else's sign-in can be taken. A
  # browser that says another site sent the post is still refused, so no page
  # can sign a visitor in as someone else.
  skip_forgery_protection only: :create
  before_action :refuse_other_sites, only: :create
  # Open to the internet, as the sign-in page is.
  rate_limit to: 10, within: 3.minutes, name: "native-sign-in"

  before_action { response.set_header("Referrer-Policy", "no-referrer") }

  def new
    unless params[:code_challenge_method] == "S256" && NativeSignIn.challenge?(params[:code_challenge])
      return render :refused, status: :unprocessable_entity
    end
    session[:native_sign_in] = { "challenge" => params[:code_challenge], "until" => PENDING_FOR.from_now.to_i }
  end

  def create
    sign_in = NativeSignIn.redeem(params[:code], verifier: params[:code_verifier])
    if sign_in && Admission.admits?(sign_in.email)
      start_session_for sign_in.user, email: sign_in.email
      session[:native_phone] = true
    else
      render :refused, status: :unprocessable_entity
    end
  end

  private
    def refuse_other_sites
      head :forbidden if request.headers["Sec-Fetch-Site"].to_s.downcase.in?(%w[ cross-site same-site ])
    end
end
