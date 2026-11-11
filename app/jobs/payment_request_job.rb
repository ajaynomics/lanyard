# Moves one payment request on (PaymentRequest#advance) and comes back when
# it says to: every few seconds while the person decides in Link's app, then
# every minute while the approved card waits to be charged, until it is paid,
# refused, cancelled or closed. One at a time per request; a second job for a
# request not yet due (one the sweep started beside a live one) does nothing.
class PaymentRequestJob < ApplicationJob
  limits_concurrency key: ->(payment_request) { payment_request }
  discard_on ActiveJob::DeserializationError

  def perform(payment_request)
    return if payment_request.next_ask_at&.future?
    wait = payment_request.advance
    payment_request.update_column(:next_ask_at, (wait.from_now if wait))
    self.class.set(wait: wait).perform_later(payment_request) if wait
  end
end
