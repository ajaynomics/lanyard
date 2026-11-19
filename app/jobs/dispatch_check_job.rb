# Asks the provider whether a message whose answer never came went
# (Dispatch#check), and again later until it is known.
class DispatchCheckJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(dispatch) = dispatch.check
end
