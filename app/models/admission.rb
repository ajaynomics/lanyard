# Who may use the app: the emails Ajent has verified, listed in settings
# (config/access.yml). Ajent says who someone is; this list says who comes in.
# It is asked at sign-in, on every request and when a live connection opens, so
# taking someone off the list ends their access at their next click. Each agent
# call can cost money, so nobody is admitted by default. A shared workspace's
# owner lets people in too, by inviting them, once an admin approves the
# invitation: until they are removed from every shared workspace
# (docs/design/workspaces.md).
class Admission
  def self.admits?(email)
    email.present? && (listed?(email) || invited?(email))
  end

  # On the install's own list. What asks a person first (sending mail,
  # inviting to an event) trusts only this list, never a workspace's invitation.
  def self.listed?(email) = DurableAssistants.config(:access, :emails, default: []).include?(email.to_s.downcase)

  # Not in an install that serves one person, where everyone admitted signs in as them.
  def self.invited?(email) = owner.nil? && Workspace.admits?(email.to_s.downcase)

  # The person the install serves, whom every admitted person signs in as
  # (User.sign_in!). Nil, the default, gives each person their own.
  def self.owner = DurableAssistants.config(:access, :owner, default: nil).presence

  # Admitted and also on the admins list: may change what every person's agents
  # share, the model accounts. Everyone else is an ordinary user.
  def self.admin?(email)
    admits?(email) && DurableAssistants.config(:access, :admins, default: []).include?(email.to_s.downcase)
  end
end
