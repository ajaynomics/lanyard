# The person approves each use. The password goes from the password manager to
# the browser on the agent's computer, never to the model: this records only
# which sign-in was used, and the sidecar, seeing `fills`, asks for the
# password once (Sidecar::SignInsController) and types it into the tab
# visit_website last opened, only in a page or frame on the sign-in's own site.
# Its security_question step does the same with the answers saved with it,
# answering the question that page asks, and nothing when none is the same.
# Given password_fields, only those password boxes get the password, so a site
# that asks for a new password twice (to set an API password, say) can save it;
# the selectors are the agent's own words, so they are kept, never the password.
class Tool::SignInWithSavedPassword < Tool
  description "Fill in a saved sign-in (see list_saved_sign_ins) on the page you last opened with visit_website " \
    "(its own tab in the screen's browser; open a sign-in page another link opened with visit_website first), in that page or a frame in it that is on that sign-in's site, with its account number too where the page has a box for one. You never see the password. Then press the page's sign-in button with the desktop tool. " \
    "The person approves it first. When the site then asks a security question, use it again with step security_question: " \
    "the saved answer to that exact question is filled and sent, and you never see it. " \
    "To set a password from a saved sign-in on a page that asks for it twice (a new password and a box to confirm it), " \
    "name each password box with password_fields: only those boxes are filled, with the password and nothing else."
  argument :name, :string, min_length: 1, max_length: 200, description: "The sign-in's name, as list_saved_sign_ins gives it."
  argument :step, :string, required: false, enum: %w[ sign_in security_question ],
    description: "sign_in, the default: the username and password. security_question: the answer to the question on the page."
  argument :password_fields, :array, required: false, min_items: 1, max_items: 4, items: { type: "string", minLength: 1, maxLength: 200 },
    description: "For the sign_in step only: a CSS selector for each password box to fill, such as the new password box and its confirm box. " \
      "Each must be a password box on the page; nothing else is filled."
  # Each fill needs its own approval: the password goes only soon after one.
  asks :approval, always: false, even_approving_everything: true
  reaches_others
  effect :external

  # The sidecar may collect the password this long after the person approved.
  FILL_WITHIN = 5.minutes
  # The sidecar waits a minute for the password (SIGN_IN_WAIT_MS in
  # agent/server.mjs); the password manager takes 15 to 25 seconds. One
  # fetched later than this may reach nobody, so the approval is not spent
  # on it (Invocation#redeem_sign_in). It is less than the minute to allow
  # for the request's own way to Rails and back. A card from Link
  # (Invocation#redeem_card) has the same wait and the same limit.
  FETCH_WITHIN = 45.seconds

  def self.fills? = true

  FIELDS_ON_QUESTION = "password_fields are for the sign_in step only, not security_question.".freeze
  RESERVED = "That sign-in belongs to your own mail or calendar account, so it can't be filled in a browser.".freeze

  # Refused before anyone is asked, and again when the password is collected
  # (Invocation#redeem_sign_in), in case the account took it meanwhile.
  def refusal = (RESERVED if agent.reserved_sign_in?(arguments["name"]))

  def call(name:, step: "sign_in", password_fields: nil)
    raise Refusal, RESERVED if agent.reserved_sign_in?(name)
    raise Refusal, FIELDS_ON_QUESTION if password_fields && step != "sign_in"
    sign_in = DurableAssistants::Passbolt.find_by_name(agent, name)
    { signIn: sign_in.name, site: sign_in.address, step:, passwordFields: password_fields, browser: agent.browser_without_desktop }.compact
  rescue DurableAssistants::Passbolt::Error => error
    raise Refusal, error.message
  end
end
