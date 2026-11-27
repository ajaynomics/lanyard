# Why the phone app's Turn on gave no device (Push::Attempt): the page says
# when the app lacks the component, the iPhone never answers or Rails refused
# the token (native/push_device_controller); the app says when iOS refused or
# failed, with iOS's error code (PushRegistration). Never a token.
#
# The app also says iOS refused each time it comes to the front while the
# iPhone's Settings has notifications off: this iPhone's token, if Rails holds
# one, is then refused (Push::Device#reported). Said again and again, it is
# kept once, so it doesn't push out the outcomes that say why.
class Push::AttemptsController < ApplicationController
  def create
    attempt = Current.user.push_attempts.new(outcome: params.expect(:outcome), code: params[:code].presence&.to_i, user_agent: request.user_agent)
    Current.user.push_devices.this_session(session)&.reported(refused: true) if attempt.outcome == "refused"
    if repeated_refusal?(attempt)
      head :ok
    elsif attempt.save
      head :created
    else
      head :unprocessable_entity
    end
  end

  private
    def repeated_refusal?(attempt)
      attempt.outcome == "refused" && Current.user.push_attempts.order(id: :desc).pick(:outcome, :code) == [ attempt.outcome, attempt.code ]
    end
end
