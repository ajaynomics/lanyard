# A person who checked the phone, the provider's log or the Sent folder says
# whether a message still unknown went (Dispatch#close), and the agent is told. The card
# is redrawn by broadcast; one still being checked, or known already, says so.
class Conversations::Invocations::DispatchesController < ApplicationController
  include InvocationScoped
  include RedrawnByBroadcast

  WENT = { "sent" => true, "not_sent" => false }.freeze

  def update
    dispatch = @invocation.dispatch or raise ActiveRecord::RecordNotFound
    went = WENT.fetch(params.expect(:state)) { raise ActionController::BadRequest, "a message either went or didn't" }
    redrawn_by_broadcast dispatch.close(went: went, by: Current.user),
      refusal: "Whether that went isn't for a person to say now: it is still being checked, or is known.", fallback: @conversation
  end
end
