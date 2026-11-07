# Who may use the app: the emails Ajent has verified, listed in settings
# (config/access.yml). Ajent says who someone is; this list says who comes in.
# It is asked at sign-in, on every request and when a live connection opens, so
# taking someone off the list ends their access at their next click. Each bot
# call can cost money, so nobody is admitted by default.
class Admission
  def self.admits?(email)
    email.present? && DurableAssistants.config(:access, :emails, default: []).include?(email.to_s.downcase)
  end
end
