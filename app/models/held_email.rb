# Mail allowed outside the agent's sending hours, held until they open
# (Agent::SendingHours, docs/email.md): the send_email call it came from holds
# the message as allowed, and its files stay with it. A sweep each minute
# (HeldEmailSweepJob) sends what is due, through the same mailer, so the
# owner's forced Bcc goes too; a person may cancel it before then. Either
# way the agent is told once, and the thread shows where it stands.
class HeldEmail < ApplicationRecord
  STATES = %w[ held sending sent cancelled failed ].freeze
  # Sending, with no word back after this: whether it went is unknown, so it
  # is never sent again (as Invocation::RUN_LIMIT).
  SEND_LIMIT = 5.minutes

  belongs_to :conversation
  belongs_to :invocation
  belongs_to :cancelled_by, class_name: "User", optional: true

  enum :state, STATES.index_by(&:itself), default: :held
  delegate :agent, to: :conversation

  after_commit -> { invocation.show }, on: :update, if: :saved_change_to_state?

  def self.sweep
    held.where(send_at: ..Time.current).find_each(&:send_now) # tenancy-ok: the sweep sends every owner's due mail
    sending.where(updated_at: ...SEND_LIMIT.ago).find_each(&:lost) # tenancy-ok: and settles every owner's lost sends
  end

  def to = invocation.arguments["to"].to_a
  def subject = invocation.arguments["subject"]

  # Due, and the hours still open: it goes, once. Hours closed again (changed
  # meanwhile) hold it until they open.
  def send_now
    claimed = with_lock do
      next false unless held? && send_at.past?
      later = agent.held_until
      later ? update!(send_at: later) : update!(state: :sending)
      later.nil?
    end
    return unless claimed
    Tool::SendEmail.new(invocation).send_held
    update!(state: :sent, sent_at: Time.current)
    tell "The email #{described}, was sent #{Conversation.stamp(sent_at, agent.time_zone)}."
  rescue Tool::Refusal => refusal
    update!(state: :failed, error: refusal.message.truncate(1_000))
    tell "The email #{described}, was not sent: #{error}"
  end

  # False when it is no longer held: sent, being sent, or cancelled already.
  def cancel(by:)
    cancelled = with_lock { held? && update!(state: :cancelled, cancelled_by: by) }
    tell "#{by.name} cancelled the email #{described}. It was not sent." if cancelled
    cancelled
  end

  def lost
    settled = with_lock { update!(state: :failed, error: Invocation::LOST) if sending? }
    tell "The email #{described}, may or may not have gone: #{error}" if settled
  end

  private
    def described = "to #{to.to_sentence}, #{subject.to_json}, held for your sending hours"

    # Once, by its request id: a retry is the same message.
    def tell(text) = HeldEmailReportJob.perform_later(self, text)
end
