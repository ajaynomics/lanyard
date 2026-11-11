# One payment an agent asked for with a one-time card from its person's Link
# wallet (Tool::PayByCard, docs/payments.md): how much, to whom, where and
# why, and where it stands at Link. The person approves it in Link's app,
# never here. Approved, its card is filled into the checkout page for the
# agent (Invocation#redeem_card). It keeps the card's brand and last four
# digits, never its number.
#
# PaymentRequestJob moves it on: sends it to Link, waits for the person's
# answer there, then watches the card until it is charged, refused or runs
# out. A card that will not be used is closed at Link: on expiry, on a
# failure, and when the person cancels.
class PaymentRequest < ApplicationRecord
  STATES = %w[ requested waiting approved declined expired canceled paid failed ].freeze
  OPEN = %w[ requested waiting approved ].freeze
  # How often the job asks Link: while the person decides, then while an
  # approved card waits to be charged.
  ASK_EVERY = 3.seconds
  WATCH_EVERY = 1.minute
  # How long an approved card is watched when Link doesn't say how long it lasts.
  CARD_LASTS = 12.hours
  # How late a job may be before PaymentRequestSweepJob starts another.
  OVERDUE = 5.minutes
  # Currencies without minor units, for showing an amount.
  WHOLE = %w[ bif clp djf gnf jpy kmf krw mga pyg rwf ugx vnd vuv xaf xof xpf ].freeze

  belongs_to :invocation
  delegate :conversation, :user, to: :invocation

  enum :state, STATES.index_by(&:itself), default: :requested

  # Open, and its job should have asked Link long ago.
  scope :overdue, -> {
    where(state: OPEN).where(created_at: ...OVERDUE.ago).where(next_ask_at: nil).or(where(state: OPEN, next_ask_at: ...OVERDUE.ago))
  }

  after_create_commit -> { PaymentRequestJob.perform_later(self) }
  after_update_commit -> { invocation.show_progress }

  # The call's payment, made once however often the call is asked about.
  def self.open!(invocation)
    arguments = invocation.arguments
    create_or_find_by!(invocation: invocation) do
      it.amount = arguments["amount"]
      it.currency = arguments["currency"].to_s.downcase
      it.payee = arguments["payee"]
      it.checkout_url = arguments["checkout_url"]
      it.reason = arguments["reason"]
    end
  end

  def open? = state.in?(OPEN)
  def site = URI(checkout_url).host
  def card_shown = ("#{card_brand.to_s.titleize.presence || "Card"} ending #{card_last4}" if card_last4)

  # Link's reason as a sentence.
  def failure_shown = (failure.presence || "Link refused it").sub(/(?<![.!?])\z/, ".")

  def amount_shown
    places = WHOLE.include?(currency) ? 0 : 2
    value = ActiveSupport::NumberHelper.number_to_delimited(format("%.#{places}f", amount / 10.0**places))
    currency == "usd" ? "$#{value}" : "#{value} #{currency.upcase}"
  end

  # One step of the job: the next look, or nil when there is nothing more to wait for.
  def advance
    case state
    when "requested" then submit
    when "waiting" then await_answer
    when "approved" then watch
    end
  rescue DurableAssistants::Link::Error => error
    Rails.logger.warn("Link, for payment request #{id}: #{error.message}")
    return fail!("Link refused the request: #{error.message}", call: true) if requested?
    expires_at&.past? || card_valid_until&.past? ? close!(:expired) : WATCH_EVERY
  end

  # The person takes it back: at Link first, so a card that might still be
  # charged is closed before this says it is.
  def cancel!(by:)
    raise Invocation::Conflict unless open?
    DurableAssistants::Link.cancel(user.wallet_token, link_id) if link_id
    with_lock { update!(state: :canceled, decided_by: by.to_s) if open? }
    invocation.deny!(by: by) if invocation.answerable?
  end

  # The card, number and all, for the agent's browser alone (Invocation#redeem_card).
  def card
    card = DurableAssistants::Link.card(user.wallet_token, link_id)
    update!(filled_at: Time.current, card_valid_until: (Time.zone.parse(card["valid_until"].to_s) rescue nil) || card_valid_until)
    { "number" => card.fetch("number"), "cvc" => card["cvc"], "exp_month" => card["exp_month"], "exp_year" => card["exp_year"],
      "name" => card.dig("billing_address", "name"), "postal_code" => card.dig("billing_address", "postal_code"), "site" => site }
  end

  private
    def token = user.wallet_token

    # Link's request names the payee and the page, and says why in at least
    # the 100 characters Link asks for. Its key makes a repeat the same request.
    def submit
      context = "#{reason} Paying #{payee} #{amount_shown} on #{checkout_url}, asked for by the agent #{invocation.agent}."
      answer = DurableAssistants::Link.create(token, key: "payment-#{invocation.digest.first(40)}", amount: amount, currency: currency,
        merchant_name: payee, merchant_url: checkout_url, context: context.ljust(100, "."))
      return ASK_EVERY if move!(:requested, state: :waiting, link_id: answer.fetch("id"), approval_url: answer["approval_url"],
        expires_at: link_time(answer["expires_at"]) || DurableAssistants::Link::APPROVE_WITHIN.from_now)
      # Cancelled while it was being sent: Link closes the request it just made.
      DurableAssistants::Link.cancel(token, answer.fetch("id"))
      nil
    end

    def await_answer
      answer = DurableAssistants::Link.retrieve(token, link_id)
      case answer["status"]
      when "approved"
        return unless move!(:waiting, state: :approved, card_brand: answer["card_brand"], card_last4: answer["card_last4"],
          card_valid_until: CARD_LASTS.from_now)
        invocation.settle_payment!(:approved)
        WATCH_EVERY
      when "denied" then settle!(:declined, call: :declined)
      when "expired", "canceled" then close!(:expired)
      when "failed", "requires_action" then fail!(link_failure(answer), call: true)
      else expires_at.past? ? close!(:expired) : ASK_EVERY
      end
    end

    # An approved card: charged, refused, or unused until it runs out.
    def watch
      answer = DurableAssistants::Link.retrieve(token, link_id)
      outcome = answer.dig("payment_status_details", "outcome")
      if outcome == "success" || answer["status"] == "succeeded" then settle!(:paid)
      elsif outcome == "failure" || answer["status"] == "failed" then fail!(link_failure(answer, "The charge was declined"))
      elsif card_valid_until.past? || answer["status"].in?(%w[ expired canceled ]) then close!(:expired)
      else WATCH_EVERY
      end
    end

    # Changes it only if it still stands where this step found it: a person's
    # cancel, made meanwhile, wins.
    def move!(from, **changes)
      with_lock { state == from.to_s && update!(changes) }
    end

    def link_time(value) = (Time.zone.parse(value) if value.present?) rescue nil

    def link_failure(answer, what = "Link refused it")
      details = answer["status_details"].to_h
      code = answer.dig("payment_status_details", "decline_code") || answer.dig("payment_status_details", "code") ||
        details.dig("failed", "code") || details.dig("requires_action", "failure_code")
      message = details.dig("requires_action", "next_action", "display_message") || details.dig("failed", "next_action", "display_message")
      [ what, ("(#{code})" if code), (": #{message}" if message) ].compact.join(" ").sub(" :", ":")
    end

    # The card is closed at Link, so nothing can charge it after this.
    def close!(state, **changes)
      DurableAssistants::Link.cancel(token, link_id) if link_id
      settle!(state, call: (:expired if state == :expired), **changes)
    rescue DurableAssistants::Link::Error => error
      Rails.logger.warn("Link didn't close payment request #{id}'s card: #{error.message}")
      settle!(state, call: (:expired if state == :expired), **changes)
    end

    def fail!(message, call: false)
      close!(:failed, failure: message.truncate(250)).tap do
        invocation.settle_payment!(:failed, message) if call && invocation.answerable?
      end
    end

    # The new state, and the waiting call's answer when it is still waiting.
    def settle!(state, call: nil, **changes)
      return unless with_lock { open? && update!(state: state, **changes) }
      case call
      when :declined then invocation.settle_payment!(:declined) if invocation.answerable?
      when :expired then invocation.settle_payment!(:failed, "The person didn't approve it in Link within 30 minutes, so nothing was paid.") if invocation.answerable?
      end
      nil
    end
end
