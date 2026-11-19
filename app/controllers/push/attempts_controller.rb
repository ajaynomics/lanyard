# Why the phone app's Turn on gave no device (Push::Attempt): the page says
# when the app lacks the component, the iPhone never answers or Rails refused
# the token (native/push_device_controller); the app says when iOS refused or
# failed, with iOS's error code (PushRegistration). Never a token.
class Push::AttemptsController < ApplicationController
  def create
    attempt = Current.user.push_attempts.new(outcome: params.expect(:outcome), code: params[:code].presence&.to_i, user_agent: request.user_agent)
    if attempt.save
      head :created
    else
      head :unprocessable_entity
    end
  end
end
