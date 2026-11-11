# The person takes back a payment their agent asked for: before Link's
# approval, or after it while the card is unused. Link closes it first.
class Conversations::Invocations::PaymentsController < ApplicationController
  include InvocationScoped

  rescue_from DurableAssistants::Link::Error do |error|
    redirect_to @conversation, alert: "Couldn't cancel it at Link, so it may still be used: #{error.message}", status: :see_other
  end

  def destroy
    payment = @invocation.payment_request or raise ActiveRecord::RecordNotFound
    payment.cancel!(by: Current.user)
    ahoy.track "Payment cancelled", agent_id: @conversation.agent_id
    redirect_to @conversation, status: :see_other
  end
end
