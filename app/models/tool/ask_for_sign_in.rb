# How an agent gets a sign-in it was not given: the person types the username
# and password into a form on their own page of the thread, which saves them
# straight to the install's password manager as the agents' user
# (Conversations::Invocations::SignInsController). The model learns only that
# it was saved; it then uses it like any other (sign_in_with_saved_password).
class Tool::AskForSignIn < Tool
  description "Ask the person to save a sign-in for a site you need to sign in to, when list_saved_sign_ins has none. " \
    "They type it into a form you never see; it is saved to the password manager under the name you give. " \
    "Then use it with sign_in_with_saved_password."
  argument :name, :string, min_length: 1, max_length: 100, description: "What to call it, such as \"Bank\"."
  argument :site, :string, max_length: 500, pattern: "^https://[^\\s/@]+(/\\S*)?$", description: "The sign-in page's https address."
  argument :why, :string, required: false, max_length: 300, description: "One line for the person: what you need it for."
  asks :sign_in

  def call(name:, site:, **)
    invocation.approval&.decision == "approve" or raise Refusal, "The person did not save it."
    { saved: name, site: site }
  end
end
