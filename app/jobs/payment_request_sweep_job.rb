# Every five minutes (config/recurring.yml), deliberately global: a payment
# whose job was lost, its worker killed or its queue cleared, is asked about
# again, so it still expires and its card is still closed at Link.
class PaymentRequestSweepJob < ApplicationJob
  def perform
    PaymentRequest.overdue.find_each { PaymentRequestJob.perform_later(it) } # tenancy-ok: the sweep looks after every person's open payments
  end
end
