# Ajent authenticates; this controller turns a verified identity into a
# session, for the addresses the app admits. If Ajent cannot be reached, nobody
# is let in.
class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create failure ]
  # Open to the internet: each answer is a page. The callback's own limit is
  # ahead of OmniAuth (DurableAssistants::SignInLimit), which answers some itself.
  rate_limit to: 30, within: 1.minute, only: %i[ new failure ], name: "pages"

  before_action only: %i[ create failure ] do
    response.set_header("Referrer-Policy", "no-referrer")
  end

  def new
    # Signing in from this page is for this browser, even if the phone app's
    # sign-in was begun here and left (NativeSignIn).
    session.delete(:native_sign_in)
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

    user = User.sign_in!(sub: auth.uid, email: email, name: claims["name"].presence || auth.dig("info", "name"))
    complete_sign_in user, email: email, workspace: user.accept_invitations
  end

  def destroy
    forget_the_phone if params[:phone] == "forget"
    reset_session
    respond_to do |format|
      # The app's Settings page tells the app itself (native/session_controller), which starts its tabs afresh.
      format.html { resume_or_redirect_to sign_in_path, status: :see_other }
      format.json { head :no_content }
    end
  end

  # OmniAuth lands here for every failure. config/initializers/omniauth.rb marks
  # the ones where Ajent could not be reached or answered with a server error:
  # a different thing to tell someone from a refusal.
  def failure
    reset_session
    return render :unreachable, status: :service_unavailable if params[:message] == "unreachable"
    redirect_to sign_in_path, alert: "Sign-in did not complete." # turbo-ok: GET from OmniAuth
  end

  private
    # The phone app's Sign out, on its Settings page or from a build reading
    # ios_v2, whose own screen sends JSON, takes its Watch's token and its
    # notifications with the session: the Watch, refused, forgets its token,
    # and this phone is notified no more. The page knows the phone by the
    # session that posted its token (Push::Device.this_session); an older
    # build names its token.
    def forget_the_phone
      Current.user.watches.active.find_each(&:revoke!)
      Current.user.push_devices.this_session(session)&.destroy
      Current.user.push_devices.where(token: params[:device_token].to_s).destroy_all if params[:device_token].present?
    end
end
