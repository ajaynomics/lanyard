# Every page needs a signed-in person unless it says otherwise. The session
# holds only the user id; Ajent proved who they are at sign-in, or, where
# Cloudflare Access is the boundary and Ajent is not set up, Access's signed
# assertion did. Nothing else identifies anyone: no header, no address.
module Authentication
  extend ActiveSupport::Concern

  NOT_ADMITTED = "That account is not set up here.".freeze

  included do
    before_action :require_sign_in
    helper_method :signed_in?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_sign_in, **options
    end
  end

  private
    def signed_in? = Current.user.present?

    # main_app, because Active Storage's controllers include this too
    # (config/initializers/active_storage.rb) and have no route helpers of ours.
    def require_sign_in
      Current.user = User.find_by(id: session[:user_id]) if session[:user_id] # tenancy-ok: the session names the signed-in person
      # Asked on every request, from what was stored at sign-in, so taking
      # someone off the list ends their session without a call to Ajent.
      if Current.user && !Admission.admits?(Current.user.email)
        Current.user = nil
        reset_session
        return redirect_to main_app.sign_in_path, alert: NOT_ADMITTED, status: :see_other
      end
      return if Current.user || sign_in_through_access
      session[:return_to] = request.fullpath if request.get? || request.head?
      redirect_to main_app.sign_in_path, status: :see_other
    end

    # Access asserts on every request it lets through, so there is no sign-in
    # page to visit: an admitted, verified identity starts a session here. The
    # person is their verified email, as the admitted list is: Access's own
    # subject can differ between its Google and email-code sign-ins. Only where
    # Ajent is not set up: once it is, Ajent is the one way to start a session,
    # which is also what lets it be proved while Access is still in front.
    def sign_in_through_access
      return if DurableAssistants::Oidc.configured?
      identity = CloudflareAccess.identity(request)
      return unless identity && Admission.admits?(identity.email)
      # Someone Ajent has since claimed is found by their email, not made again empty.
      Current.user = User.find_by(email: identity.email) || # tenancy-ok: the person Access verified, by the email the list names
        User.sign_in!(sub: "cloudflare-access:#{identity.email}", email: identity.email, name: nil)
      reset_session
      session[:user_id] = Current.user.id
    end

    def start_session_for(user)
      return_to = session[:return_to]
      reset_session
      session[:user_id] = user.id
      redirect_to safe_return_path(return_to) # turbo-ok: identity providers return the browser here by GET
    end

    def safe_return_path(path)
      path.is_a?(String) && path.start_with?("/") && !path.start_with?("//") ? path : root_path
    end
end
