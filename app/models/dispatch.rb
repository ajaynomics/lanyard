# One message an agent's call hands to an outside provider, recorded and
# committed before the provider is asked (docs/phone.md, "When voip.ms is
# slow to answer"; docs/email.md, "When the mail server doesn't answer"). A
# provider can take a message and never answer, so a call that only remembered its answer would not know whether it sent. With
# this, the call knows it tried: the same call never sends again, a retry of
# the same message soon after is refused, and one whose answer never came is
# looked up at the provider, now and then in the background, until it is
# found to have gone, and the agent is told. One the provider never lists is
# never called "not sent": it stays unknown until a person who checked says
# whether it went (#close).
class Dispatch < ApplicationRecord
  STATES = %w[ pending checking sent not_sent unknown check_before_resend ].freeze
  # The tools that record one, by name, each of which looks its own up
  # (find_dispatched). Any other is a connector's own send (Gmail's
  # send_message), looked up through that connector.
  TOOLS = [ Tool::SendText, Tool::ConcourseSend, Tool::ImessageSend, Tool::SendEmail, Tool::TelegramSend,
    Tool::CalendarSaveEvent, Tool::CalendarDelete ].index_by(&:tool_name).freeze
  # The first look, once the call's own wait and lookup are surely over.
  CHECK_AFTER = 2.minutes
  # Looked for and listed nowhere this long after, or the provider could not
  # be asked for this long: checking stops, whether it went stays unknown,
  # and a person must look.
  NOT_LISTED_AFTER = 1.hour
  CHECK_FOR = 1.day
  # The same words to the same recipient again this soon after one went are
  # the agent retrying, not a second message.
  REPEAT_WITHIN = 10.minutes

  class LookupFailed < StandardError; end
  # The provider lists nothing that was sent (Telegram), so asking again
  # never helps: unknown at the first check, for a person to say.
  class Unaskable < LookupFailed; end

  # How a message is named to a person and to the agent, and where a person
  # looks to see whether it went: each tool says its own (dispatch_words).
  Words = Data.define(:noun, :to, :excerpt, :provider, :log) do
    # "Text to", but "iMessage to": a name already cased stays as it is.
    def title = "#{noun.match?(/\A[a-z][A-Z]/) ? noun : noun.upcase_first} to #{to}"
    def described = "#{noun} to #{to}, #{excerpt.truncate(80).to_json}"
  end

  belongs_to :invocation
  # Who said whether one still unknown went.
  belongs_to :closed_by, class_name: "User", optional: true
  has_secure_token :key, length: 24

  # No class-level scopes: Dispatch.not_sent would be both the state and the
  # negation of sent, and nothing queries by state. Ask with where(state:).
  enum :state, STATES.index_by(&:itself), default: :pending, scopes: false
  delegate :conversation, :agent, to: :invocation

  # Preserve the attempted send until the provider or a person confirms it.
  scope :waiting, -> { where(state: %w[ pending checking unknown check_before_resend ]) }

  after_commit -> { invocation.show }, on: :update, if: :saved_change_to_state?

  # Looked at once the call should have ended, however it ended: a crash
  # mid-send leaves it pending, and the call lost.
  after_create_commit -> { DispatchCheckJob.set(wait: CHECK_AFTER).perform_later(self) }

  # One message's identity, for telling a retry from a new message.
  def self.fingerprint(*parts) = Digest::SHA256.hexdigest(parts.join("\u0000"))

  # Recorded, before the provider is asked. Nil when the call has one
  # already: it was tried, so it is never sent again. Mail's id is its
  # Message-ID, chosen first, so it is known before the server is asked.
  def self.record(invocation, tool_name:, sender:, fingerprint:, provider_id: nil)
    return if invocation.dispatch
    invocation.create_dispatch!(tool_name: tool_name, sender: sender, fingerprint: fingerprint, provider_id: provider_id)
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  # A refusal settles only its own attempt. It cannot clear an earlier
  # attempt that may have gone or that went recently.
  def self.repeated(fingerprint, by:)
    matches = where(fingerprint: fingerprint).where.not(invocation_id: by.id)
    matches.waiting.or(matches.where(state: :sent, created_at: REPEAT_WITHIN.ago..)).order(:created_at).last
  end

  def words = lookup.dispatch_words(invocation.call_arguments)

  # Mail, sent under a Message-ID chosen first (Tool::SendsMailOnce), which
  # a person looks for in the Sent folder.
  def mail? = lookup.dispatches_mail?

  def settled? = sent? || not_sent? || needs_person_check?
  def needs_person_check? = unknown? || check_before_resend?

  # The provider answered: it went, with its id.
  def confirm(id) = update!(state: :sent, provider_id: id.to_s, settled_at: Time.current)

  # The provider refused it, or was never reached: nothing went.
  def refused = update!(state: :not_sent, settled_at: Time.current)

  # An explicit server error failed the call, but isn't proof of non-delivery.
  def require_provider_check = update!(state: :check_before_resend, settled_at: Time.current)

  # Asks the provider once, within the call, whether it went: confirmed if
  # it is listed, and otherwise left to the checks.
  def look_up
    id = lookup.find_dispatched(self)
    confirm(id) if id
  rescue LookupFailed
    nil
  end

  # Nothing may be asked whether it went (mail through the install's own
  # server has no Sent folder this app may read): unknown at once, for a
  # person to say.
  def unconfirmable = update!(state: :unknown, settled_at: Time.current)

  # Something later showed the provider's id for a message whose answer
  # never came: a Telegram reply quotes the post it answers, whole
  # (TelegramBot#reveal_send). It went, and the agent is told once, as a
  # check that found it would.
  # Only one still waiting: a person's answer stands. Told under its own
  # request id, since a check may already have said it was unknown.
  def revealed(found)
    went = with_lock { (pending? || checking? || unknown?) && closed_by_id.nil? &&
      update!(state: :sent, provider_id: found.to_s, settled_at: Time.current) }
    DispatchReportJob.perform_later(self, report(nil), "dispatch:#{id}:revealed") if went
  end

  # Asks the provider whether it went (DispatchCheckJob), until it is known.
  def check
    return if settled?
    return check_later if invocation.calling_outside? && invocation.updated_at.after?(Invocation::RUN_LIMIT.ago)
    increment!(:checks)
    if (id = lookup.find_dispatched(self)) then settle(:sent, found: id)
    elsif created_at.before?(NOT_LISTED_AFTER.ago) then settle(:unknown, why: "an hour on, #{words.provider} lists it nowhere")
    else check_later
    end
  rescue Unaskable
    settle(:unknown, why: "#{words.provider} can't be asked whether it went")
  rescue LookupFailed
    created_at.before?(CHECK_FOR.ago) ? settle(:unknown, why: "#{words.provider} could not be asked for a day") : check_later
  end

  # The person checks the source named on the card before answering.
  def close(went:, by:)
    manual_retry_only = false
    closed = with_lock do
      manual_retry_only = check_before_resend?
      needs_person_check? && update!(state: went ? :sent : :not_sent, closed_by: by, settled_at: Time.current)
    end
    if closed
      next_step = if went then "it went. Don't send it again."
      elsif manual_retry_only then "it didn't go. Don't resend unless your person asks for a new send."
      else "it didn't go. Send it again if it is still wanted."
      end
      DispatchReportJob.perform_later(self, "#{by.name} checked the #{words.described}, and says #{next_step}", "dispatch:#{id}:closed")
    end
    closed
  end

  # Where a person looks to say whether one still unknown went.
  def where_to_check = mail? ? "the Sent folder for Message-ID <#{provider_id}>, or ask the recipient" : words.log

  private
    def lookup = TOOLS.fetch(tool_name) { Tool::Mcp }

    # Settled from the provider's list, and the agent told once. Never "not
    # sent" from what it doesn't list: voip.ms may list a text with other
    # words than those sent, Concourse says a missing receipt is no proof,
    # a Sent folder holds only what its server chose to file there, and
    # "not sent" invites a second send.
    def settle(state, found: nil, why: nil)
      settled = with_lock { !settled? && update!(state: state, provider_id: (found || provider_id)&.to_s, settled_at: Time.current) }
      DispatchReportJob.perform_later(self, report(why), "dispatch:#{id}") if settled
    end

    def report(why)
      called = "#{tool_name} #{invocation.call_arguments.to_json}, sent #{Conversation.stamp(created_at, agent.time_zone)} without an answer at the time"
      if sent? then "#{called}, went after all: its id is #{provider_id}. Don't send it again."
      else "#{called}, is still unknown: #{why}, so it may or may not have gone. Don't send it again; ask your person, " \
        "who can check #{where_to_check} and say on the #{words.noun}'s card whether it went (key #{key})."
      end
    end

    def check_later
      DispatchCheckJob.set(wait: [ CHECK_AFTER * 2**checks, 1.hour ].min).perform_later(self)
    end
end
