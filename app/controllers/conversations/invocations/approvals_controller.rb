# A person allows one exact tool call, or allows it always (Permission), or
# denies it. What "Always" covers comes from the call, never from the form.
#
# The Watch asks for JSON with its own token, and answers the card it showed
# (Invocation::Card): it names the card's version, and allows only a small
# card, once.
class Conversations::Invocations::ApprovalsController < ApplicationController
  include InvocationScoped
  allow_watch_access only: :create

  before_action :answer_shown_card, if: -> { request.format.json? }
  rescue_from Invocation::NotTheApprover, with: :not_the_approver

  def create
    case params.expect(:decision)
    when "approve"
      # A sign-in is approved only by saving it (SignInsController), and a
      # question only by its answer.
      raise Invocation::Conflict unless @invocation.asks == :approval
      always = params[:always].presence
      raise ActionController::BadRequest if always && !@invocation.always_choices.include?(always)
      @invocation.approve!(by: Current.user, always: always)
    when "deny"
      # The sign-in card's Decline comes here too.
      raise Invocation::Conflict unless @invocation.asks.in?(%i[ approval sign_in ])
      @invocation.deny!(by: Current.user)
    else raise ActionController::BadRequest
    end
    ahoy.track "Approval answered", agent_id: @conversation.agent_id, tool: @invocation.call_name, decision: params[:decision], always: always
    if request.format.json?
      render json: Invocation::Card.new(@invocation.reload)
    elsif params[:from] == "approvals"
      answered_from_needs_you
    else
      redirect_to @conversation, status: :see_other
    end
  end

  private
    # A call only one person may allow (Tool#approver), answered by another
    # member: refused, and back to the card, which still waits for them.
    def not_the_approver
      if request.format.json?
        render json: Invocation::Card.new(@invocation.reload).as_json.merge(error: "not_the_approver"), status: :forbidden
      else
        redirect_back_or_to @conversation, alert: "Only #{@invocation.approver} can allow this.", status: :see_other
      end
    end

    # From the card alone (approvals/show): the phone app closes its sheet and
    # refreshes Needs you beneath, which says what was done as a toast; a
    # browser goes back to the list. The flash outlives the app's refresh
    # signal, which reads none, for the list it refreshes.
    def answered_from_needs_you
      flash[:notice] = params[:decision] == "approve" ? "Allowed." : "Denied."
      refresh_or_redirect_to approvals_path, status: :see_other
    end

    # The same answer again is the answer already given, so a reply lost on
    # the way and asked again decides nothing twice. A card that changed since
    # it was shown, or is too long for the small screen, is not allowed from it.
    # Declining is always safe, so it is applied whatever card was shown.
    def answer_shown_card
      card = Invocation::Card.new(@invocation)
      raise ActionController::BadRequest if params[:always].present?
      if card.decided?(params[:decision], by: Current.user)
        render json: card
      elsif !@invocation.answerable?
        raise Invocation::Conflict
      elsif params[:decision] != "deny" && !card.current?(params[:version])
        render json: card.as_json.merge(error: "changed"), status: :conflict
      elsif params[:decision] == "approve" && !card.small?
        render json: card.as_json.merge(error: "phone_only"), status: :conflict
      end
    end
end
