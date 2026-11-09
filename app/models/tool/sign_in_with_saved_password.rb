# The person approves each use. The password goes from the password manager to
# the browser on the agent's computer, never to the model: this records only
# which sign-in was used, and the sidecar, seeing `fills`, asks for the
# password once (Sidecar::SignInsController) and types it into the page
# visit_website last opened, only if that page is on the sign-in's own site.
class Tool::SignInWithSavedPassword < Tool
  description "Fill in a saved sign-in (see list_saved_sign_ins) on the page you last opened with visit_website, which must be " \
    "on that sign-in's site. You never see the password. Then press the page's sign-in button with the desktop tool. " \
    "The person approves it first."
  argument :name, :string, min_length: 1, max_length: 200, description: "The sign-in's name, as list_saved_sign_ins gives it."
  # Each fill needs its own approval: the password goes only soon after one.
  asks :approval, always: false
  reaches_others
  effect :external

  # The sidecar may collect the password this long after the person approved.
  FILL_WITHIN = 5.minutes

  def self.fills? = true

  def call(name:)
    sign_in = DurableAssistants::Passbolt.find_by_name(agent, name)
    { signIn: sign_in.name, site: sign_in.address }
  rescue DurableAssistants::Passbolt::Error => error
    raise Refusal, error.message
  end
end
