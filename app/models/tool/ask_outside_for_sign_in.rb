# How an agent gets a sign-in from someone outside the install (a client's
# lawyer, say) without it passing through the agent or a chat: a one-time
# link to a page where they type it straight into one empty vault entry
# (SignInLink). The agent sends the link on itself and hears later only
# whether the entry was filled.
#
# The link lets a stranger write into the vault, so the person approves every
# one, never "Always", even where the install approves everything. Only an
# entry shared with the agent and still empty gets one: a saved password is
# never overwritten.
class Tool::AskOutsideForSignIn < Tool
  description "Get a one-time link for someone outside (a client, their lawyer) to type a sign-in straight into the password " \
    "manager, so it never passes through you or a chat. Name an entry shared with you that has no password yet; someone " \
    "must make it in the password manager first. Send them the link yourself. It works once and lasts 30 minutes. " \
    "You are told later whether it was filled, never what was typed. The person approves it first, every time."
  argument :name, :string, min_length: 1, max_length: 200, description: "The empty entry's name, as list_saved_sign_ins gives it."
  argument :to, :string, required: false, max_length: 200, description: "Who you will send the link to, for the person approving."
  asks :approval, even_approving_everything: true
  reaches_others
  effect :external

  NOT_EMPTY = "already has a password, and a link never overwrites one. If it should change, the person must empty it " \
    "first in the password manager, then ask again."

  def self.available? = DurableAssistants::Passbolt.url.present?

  def permitted? = DurableAssistants::Passbolt.configured?(agent)

  # Its own mail or calendar account's sign-in is the app's to use (Agent#reserved_sign_in?).
  def refusal = (Tool::SignInWithSavedPassword::RESERVED.sub("filled in a browser", "filled from a link") if agent.reserved_sign_in?(arguments["name"]))

  def approval_title(arguments)
    "Let #{arguments["to"].presence || "someone outside"} fill the sign-in #{arguments["name"]}?"
  end

  def approval_note(_arguments)
    "A link anyone holding it can use once, within #{SignInLink::LASTS.inspect}, to save a username and password into this " \
      "empty entry. #{agent} sends it on, and never sees what is typed. You can revoke it from this thread."
  end

  def call(name:, **)
    raise Refusal, refusal if refusal
    found = DurableAssistants::Passbolt.find_by_name(agent, name)
    raise Refusal, "#{found.name} #{NOT_EMPTY}" if DurableAssistants::Passbolt.sign_in(agent, found.id).password.present?
    link, token = SignInLink.issue!(invocation, entry_id: found.id, name: found.name)
    { link: URI.join(DurableAssistants.config(:app, :url).to_s, Rails.application.routes.url_helpers.sign_in_link_path(token)).to_s,
      expiresAt: link.expires_at.iso8601 }
  rescue DurableAssistants::Passbolt::Error => error
    raise Refusal, error.message
  end
end
