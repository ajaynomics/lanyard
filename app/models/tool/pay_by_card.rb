# A payment with a one-time card from the person's Link wallet
# (docs/payments.md). The person approves it in Link's app, never here and
# never "always": Link pushes each request to their phone, for up to $500 and
# for 30 minutes (PaymentRequest). Approved, the card goes from Link to the
# checkout page the agent opened (Invocation#redeem_card, agent/card.mjs),
# only if that page is on the checkout's own site; the model reads which
# fields were filled, and the card's brand and last four digits.
class Tool::PayByCard < Tool
  description "Pay on a checkout page with a one-time card from the person's Link wallet. Open the checkout page with " \
    "visit_website first. The person approves the exact amount in the Link app (up to $500, within 30 minutes); then " \
    "the card is typed into that page for you, and you never see its number. Then press the page's pay button with " \
    "the desktop tool."
  argument :amount, :integer, minimum: 1, maximum: DurableAssistants::Link::LIMIT,
    description: "The total to pay, in the currency's smallest unit: 1250 is $12.50. At most 50000."
  argument :currency, :string, pattern: "^[A-Za-z]{3}$", description: "The checkout's currency, as three letters: usd."
  argument :payee, :string, min_length: 1, max_length: 200, description: "Who is paid, as the checkout names them."
  argument :checkout_url, :string, pattern: "^https://[^/\\s]+", max_length: 2_048,
    description: "The checkout page's https address. The card goes only to a page on its site."
  argument :reason, :string, min_length: 10, max_length: 1_000, description: "What it pays for, in a sentence or two the person reads before approving."
  asks :payment
  reaches_others
  effect :external

  def self.available? = DurableAssistants::Link.configured?

  # The sidecar types the card in after this call (Invocation#redeem_card).
  def self.pays? = true

  def permitted? = self.class.available?

  def refusal
    "#{user} hasn't connected a Link wallet, so nothing was asked. Ask them to connect one in Settings, under Wallet." unless user.wallet_connected?
  end

  def recipients = [ invocation.arguments["payee"].to_s ]

  def call(**)
    payment = invocation.payment_request
    raise Refusal, "The payment isn't approved in Link, so there is no card." unless payment&.approved?
    { paying: payment.amount_shown, to: payment.payee, card: payment.card_shown, site: payment.site }
  end
end
