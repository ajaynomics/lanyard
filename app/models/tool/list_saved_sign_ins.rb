class Tool::ListSavedSignIns < Tool
  description "List the sign-ins people have shared with you in the password manager: each one's name and site, never its password."
  effect :external

  def call
    { signIns: DurableAssistants::Passbolt.sign_ins(agent).map { { name: it.name, site: it.address } } }
  rescue DurableAssistants::Passbolt::Error => error
    raise Refusal, error.message
  end
end
