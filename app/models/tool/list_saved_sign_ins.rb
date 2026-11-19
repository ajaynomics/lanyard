class Tool::ListSavedSignIns < Tool
  description "List the sign-ins people have shared with you in the password manager: each one's name and site, never its password."
  effect :external

  def call
    # Those its own accounts use are not offered (Agent#reserved_sign_in?).
    { signIns: DurableAssistants::Passbolt.sign_ins(agent).reject { agent.reserved_sign_in?(it.name) }.map { { name: it.name, site: it.address } } }
  rescue DurableAssistants::Passbolt::Error => error
    raise Refusal, error.message
  end
end
