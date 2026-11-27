class Tool::RequestPhoneLocation < Tool
  description "Ask the person to share one current location fix from their signed-in iPhone. Use only when they ask for their location or something nearby. A tap on the phone is required each time. If no phone is available or they decline, no location is returned."
  asks :location, always: false

  def expires_in = 5.minutes
  def approver = invocation.user

  def call(**) = raise(Refusal, "Only the person sharing their location can finish this request.")
end
