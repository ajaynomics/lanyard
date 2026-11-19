# The buttons a notice offers, named by its category, which the phone and the
# Watch register under the same names (ios/Shared/NoticeRoute.swift, #78). A
# card's buttons are only what the Watch's own card offers: Allow once on a
# small card, Decline on any other approval. Allow once is bound to the card's
# version as it was when the notice left, so a card that changed since is
# refused; Decline always declines (Conversations::Invocations::ApprovalsController). Never Always. A question,
# a sign-in or a payment has no buttons: a tap opens it.
module Conversation::Notifiable::Buttons
  APPROVAL = "APPROVAL".freeze
  NEEDS_YOU = "NEEDS_YOU".freeze
  REPLY = "REPLY".freeze

  def self.for(invocation)
    return {} unless invocation.asks == :approval
    card = Invocation::Card.new(invocation)
    { category: card.small? ? APPROVAL : NEEDS_YOU, version: card.version }
  end
end
