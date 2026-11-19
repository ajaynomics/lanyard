# A waiting approval as a small screen shows it (the Watch, through the phone's
# app): which agent asks, to do what, to whom, and every word that matters.
# Its version names exactly that, so an answer given to a card that has since
# changed is refused rather than applied to what the person never read.
class Invocation::Card
  # A longer card, or one with files or nested data, is answered on the phone,
  # where nothing is cut; the small screen shows it but cannot allow it.
  SMALL = 1_000

  attr_reader :invocation
  delegate :id, :conversation_id, :state, to: :invocation

  def initialize(invocation)
    @invocation = invocation
  end

  def version
    Agent::Canonical.digest("call" => invocation.digest, "title" => title, "recipients" => recipients, "fields" => fields,
      "note" => note, "preview" => invocation.preview&.dig("digest"))
  end

  def current?(version) = version.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(self.version, version)

  # The same person giving the same answer again: already done, not a conflict.
  def decided?(decision, by:)
    approval = invocation.approval
    approval.present? && approval.decision == decision && approval.decided_by == by
  end

  def small?
    invocation.answerable? && invocation.asks == :approval && invocation.approvable? && !invocation.details.key?("attachments") &&
      fields.all? { it[:text] } && fields.to_json.bytesize <= SMALL
  end

  def title = invocation.approval_title || invocation.card_title

  # Which call this is, where two cards share a title (one agent forgetting two
  # notes): its first detail that the title doesn't already say.
  def gist = fields.pluck(:text).find { it.present? && it != title }

  def as_json(*)
    { id: id, conversation_id: conversation_id, agent: invocation.agent.to_s, title: title, recipients: recipients,
      fields: fields, note: note, state: state, decision: invocation.approval&.decision, version: version,
      expires_at: invocation.expires_at&.iso8601, small: small? }
  end

  private
    def note = invocation.approval_note
    def recipients = invocation.asks ? invocation.recipients : []

    # Each detail as a label and its whole text; nested data has no text and
    # keeps the card on the phone.
    def fields
      @fields ||= invocation.details.to_h.map { |key, value| { label: key.to_s.humanize, text: text_of(value) } }
    end

    def text_of(value)
      case value
      when String, Numeric, true, false then value.to_s
      when Array then value.join("\n") if value.all? { it.is_a?(String) || it.is_a?(Numeric) }
      end
    end
end
