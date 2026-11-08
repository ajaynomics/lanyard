# One notice to each of the person's devices, out of the request or frame
# that caused it: a push service can be slow, and nothing should wait on it.
# Each device's failure is its own (Push::Subscription#deliver).
class Push::DeliveryJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(user, payload)
    user.push_subscriptions.find_each { it.deliver(payload) }
  end
end
