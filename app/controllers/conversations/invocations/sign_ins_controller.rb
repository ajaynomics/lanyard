# The person saves the sign-in an agent asked for (Tool::AskForSignIn). The
# password goes from this request to the password manager and nowhere else:
# not the database, the call's result, the page or the log.
class Conversations::Invocations::SignInsController < ApplicationController
  include InvocationScoped

  def create
    raise Invocation::Conflict unless @invocation.answerable? && @invocation.asks == :sign_in
    fields = params.expect(sign_in: %i[ username password ])
    return redirect_to(@conversation, alert: "Type the username and password.", status: :see_other) if fields.values_at(:username, :password).any?(&:blank?)

    DurableAssistants::Passbolt.save(name: @invocation.arguments["name"], address: @invocation.arguments["site"],
      username: fields[:username], password: fields[:password])
    @invocation.approve!(by: Current.user)
    redirect_to @conversation, notice: "Saved. #{@invocation.agent} can use it now.", status: :see_other
  rescue DurableAssistants::Passbolt::Error => error
    redirect_to @conversation, alert: error.message, status: :see_other
  end
end
