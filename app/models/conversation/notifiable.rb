# What a person hears about while away (docs/design.md, "Notifications,
# badge and sharing"): an agent that needs them, and an agent that has
# finished a reply. Rails decides; the service worker shows it. Nothing for
# each streamed word, for the person's own messages, or for a run that ends
# without a word to the person (a routine that found nothing to say).
#
# A notice holds only the agent's name, a card's short title and the first
# words of a reply: Web Push encrypts it end to end, but it still lands on a
# lock screen. Never a tool's arguments, a secret or an email's body.
#
# The app's badge counts the agents that need the person, on every page
# (layouts/_badge, re-broadcast here) and in each notice.
module Conversation::Notifiable
  extend ActiveSupport::Concern

  NOTICE_WORDS = 120

  # A card has started waiting on the person: an approval, a question, a sign-in.
  # A person with no device to notify gets it by email instead, from the agent,
  # so an agent waiting on them is never waiting unseen.
  def notify_needs_you(invocation)
    title = "#{agent.name} needs you"
    if pushes?
      notify kind: "needs_you", title: title, body: invocation.card_title
    elsif DurableAssistants::Email.configured? && user.email.present?
      AgentMailer.needs_you(self, title: title, body: invocation.card_title).deliver_later
    end
  end

  # A run has ended. Its reply is the newest turn, after whatever started it;
  # a run that ended with the starting message still newest said nothing.
  def notify_reply
    reply = messages.where(role: %w[ user assistant ]).order(entry_id: :desc, id: :desc).first
    return unless reply&.answer?
    body = Message.plain_text(reply.content)
    notify kind: "reply", title: to_s, body: body if body.present?
  end

  def broadcast_badge
    Turbo::StreamsChannel.broadcast_replace_to user, :badge, target: "app_badge", partial: "layouts/badge", locals: { count: user.agents_needing_you }
  end

  private
    def pushes? = Push.configured? && user.push_subscriptions.exists?

    def notify(kind:, title:, body:)
      return unless pushes?
      Push::DeliveryJob.perform_later(user, { kind: kind, title: title, body: body.to_s.squish.truncate(NOTICE_WORDS),
        url: Rails.application.routes.url_helpers.conversation_path(self), tag: "conversation-#{id}", badge: user.agents_needing_you })
    end
end
