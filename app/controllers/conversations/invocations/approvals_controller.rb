# A person allows or declines one exact tool call.
class Conversations::Invocations::ApprovalsController < ApplicationController
  include InvocationScoped

  def create
    case params.expect(:decision)
    when "approve" then @invocation.approve!(by: Current.user)
    when "deny" then @invocation.deny!(by: Current.user)
    else raise ActionController::BadRequest
    end
    redirect_to @conversation, status: :see_other
  end
end
