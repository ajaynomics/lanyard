# What a person hears about while away (docs/design.md, "Notifications,
# badge and sharing"): an agent that needs them, an agent that has finished a
# reply, and one that stopped with an error. Each kind only if the person
# wants it (Push.deliver). Rails decides; the service worker shows it. Nothing for
# each streamed word, for the person's own messages, or for a run that ends
# without a word to the person (a routine that found nothing to say).
#
# A notice holds only the agent's name, a card's short title and the first
# words of a reply: Web Push encrypts it end to end, but it still lands on a
# lock screen. Never a tool's arguments, a secret or an email's body.
#
# The app's badge counts the cards waiting on the person in all their
# workspaces (User#needs_you), on every page (layouts/_badge, re-broadcast
# here whenever a card starts or stops waiting) and in each notice.
#
# "The person" is everyone in the agent's workspace, each on their own devices
# with their own badge (docs/design/workspaces.md): in a personal workspace,
# its one person; in a shared one, every member, and nobody outside it.
module Conversation::Notifiable
  extend ActiveSupport::Concern

  NOTICE_WORDS = 120

  # A card has started waiting on the person: an approval, a question, a sign-in.
  # A person with no device to notify gets it by email instead, from the agent,
  # so an agent waiting on them is never waiting unseen; not from an agent
  # other than the one they hear from alone (Workspace::Membership#sole_contact),
  # whose cards they find in the app.
  def notify_needs_you(invocation)
    title = "#{agent.name} needs you"
    buttons = Buttons.for(invocation)
    workspace.memberships.includes(:user).each do |membership|
      member = membership.user
      if Push.reaches?(member)
        notify member, kind: "needs_you", title: title, body: invocation.card_title, invocation_id: invocation.id, **buttons,
          approval_url: Rails.application.routes.url_helpers.approval_path(invocation)
      elsif workspace.agents_mail? && member.email.present? && membership.hears_from?(agent)
        AgentMailer.needs_you(self, to: member.email, title: title, body: invocation.card_title).deliver_later
      end
    end
  end

  # A run has ended. Its reply is the newest turn, after whatever started it;
  # a run that ended with the starting message still newest said nothing.
  def notify_reply
    reply = messages.where(role: %w[ user assistant ]).order(entry_id: :desc, id: :desc).first
    return unless reply&.answer?
    body = Message.plain_text(reply.content)
    members.each { notify it, kind: "reply", title: to_s, body: body, category: Buttons::REPLY } if body.present?
  end

  # A run has stopped with an error the thread shows. Said from what kind of
  # failure it was, never the failure's own text, which may hold anything.
  # Once until something goes right: runs that fail again meanwhile (a flaky
  # model, mail or a routine starting another) are not told again.
  def notify_error
    return if error_told_at
    update!(error_told_at: Time.current)
    members.each { notify it, kind: "error", title: to_s, body: Conversation::Failure.sentence(failure) }
  end

  def broadcast_badge
    members.each do |member|
      Turbo::StreamsChannel.broadcast_replace_to member, :badge, target: "app_badge", partial: "layouts/badge", locals: { count: member.needs_you_count }
    end
  end

  private
    def members = workspace.members

    def notify(member, kind:, title:, body:, **extra)
      Push.deliver member, kind: kind, agent: agent, title: title, body: body.to_s.squish.truncate(NOTICE_WORDS),
        url: Rails.application.routes.url_helpers.conversation_path(self), tag: "conversation-#{id}", conversation_id: id, **extra
    end
end
