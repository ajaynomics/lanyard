# A person allows one exact tool call, or allows it always (Permission), or
# denies it. What "Always" covers comes from the call, never from the form.
class Conversations::Invocations::ApprovalsController < ApplicationController
  include InvocationScoped

  def create
    case params.expect(:decision)
    when "approve"
      always = params[:always].presence
      raise ActionController::BadRequest if always && !@invocation.always_choices.include?(always)
      @invocation.approve!(by: Current.user, always: always)
    when "deny" then @invocation.deny!(by: Current.user)
    else raise ActionController::BadRequest
    end
    redirect_to @conversation, status: :see_other
  end
end
