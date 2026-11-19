# At a sign-in link's end (SignInLink#expire): unused, the agent hears it
# expired. Gone with its conversation, it has nothing left to end.
class SignInLinkExpiryJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(sign_in_link) = sign_in_link.expire
end
