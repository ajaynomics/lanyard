# Decide which calls may hear the thread without keeping a caller's number.
# Caller ID can be faked, so a match never lets a call act outward.
class Agent::VoiceCall::Reach
  def self.of(agent, calling_number)
    number = north_american_number(calling_number)
    # Leave the caller's number out of SQL and its logs.
    number && agent.workspace.memberships.pluck(:phone_number).include?(number) ? "owner" : "stranger"
  end

  def self.north_american_number(number)
    number = number.to_s.strip
    return if number.start_with?("+") && !number.start_with?("+1")

    digits = Workspace::Contact.normalize(number)
    digits if digits&.match?(Agent::PHONE_NUMBER)
  end
  private_class_method :north_american_number
end
