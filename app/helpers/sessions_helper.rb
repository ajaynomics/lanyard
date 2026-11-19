module SessionsHelper
  # The phone app says in its user agent that it signs in through its own
  # browser sheet (NativeSignIn). It only changes which button the sign-in
  # page shows: nothing is let in by it.
  def native_sign_in_app? = request.user_agent.to_s.include?("NativeSignIn/1")

  # Someone can sign in here: a provider is set up, or this is development.
  def sign_in_offered? = DurableAssistants::Oidc.configured? || Rails.env.development?
end
