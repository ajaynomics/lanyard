# Every page needs a signed-in person unless it says otherwise. The session
# holds only the user id; Ajent proved who they are at sign-in, or, where
# Cloudflare Access is the boundary, Access's signed assertion did.
module Authentication
  extend ActiveSupport::Concern

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

    def require_sign_in
      Current.user = User.find_by(id: session[:user_id]) if session[:user_id] # tenancy-ok: the session names the signed-in person
      return if Current.user || sign_in_through_access
      session[:return_to] = request.fullpath if request.get? || request.head?
      redirect_to sign_in_path
    end

    # Access asserts on every request it lets through, so there is no sign-in
    # page to visit: an admitted, verified identity starts a session here.
    def sign_in_through_access
      identity = CloudflareAccess.identity(request)
      return unless identity && User.admitted?(identity.email)
      Current.user = User.sign_in!(sub: "cloudflare-access:#{identity.subject}", email: identity.email, name: nil)
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
