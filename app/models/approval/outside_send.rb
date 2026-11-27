# The browser, not Rails, holds the bytes and decides whether it can still
# release them. This record keeps only the reviewed summary and a one-use
# answer; it is not an agent tool or a job that can send anything.
class Approval::OutsideSend
  KIND = "outside_send"
  TASK = "browser-hold"
  TITLE = "Allow this browser request?"
  CLOSED = "The browser is no longer waiting. It did not get an Allow."
  KEYS = %w[ id site method path targetDigest digest expiresAt fields ].freeze
  SECRET_NAME = /pass(word|code|phrase)?|secret|token|authorization|cookie|card.?num|credit.?card|cvv|cvc|security.?code|api.?key|private.?key|ssn/i

  def initialize(conversation, held_post)
    @conversation = conversation
    @ticket = held_post
    raise Invocation::Conflict unless valid?
  end

  def open
    return "deny" unless deadline.future? && deadline <= 2.minutes.from_now
    @invocation = invocations.create_or_find_by!(call_id: @ticket.fetch("id")) do |row|
      row.state = :awaiting_person
      row.arguments = @ticket.slice("site", "method", "path", "fields")
      row.digest = digest
      row.expires_at = deadline
    end
    raise Invocation::Conflict unless @invocation.digest == digest
    @invocation.answerable? || @invocation.approved? ? "waiting" : "deny"
  end

  def answer
    with_card do |card|
      if !card.expires_at.future?
        close(card)
      elsif card.approved? && card.approval&.decision == "approve"
        card.succeeded!
        "allow"
      elsif card.awaiting_person?
        "waiting"
      else
        "deny"
      end
    end
  end

  def cancel = with_card { |card| close(card) }

  private
    def invocations
      @conversation.invocations.where(task_id: TASK, tool_name: KIND)
    end

    def with_card
      card = invocations.find_by(call_id: @ticket.fetch("id"))
      return "deny" unless card
      card.with_lock do
        raise Invocation::Conflict unless card.digest == digest
        yield card
      end
    end

    def close(card)
      card.update!(state: :failed, error: CLOSED) unless card.finished?
      "deny"
    end

    def deadline = Time.at(Rational(@ticket.fetch("expiresAt"), 1_000))
    def digest = Agent::Canonical.digest(@ticket)

    def valid?
      @ticket.is_a?(Hash) && @ticket.keys.sort == KEYS.sort &&
        hex?(@ticket["id"], 48) && hex?(@ticket["targetDigest"], 64) && hex?(@ticket["digest"], 64) &&
        @ticket["method"].in?(%w[ POST PUT PATCH DELETE ]) && @ticket["expiresAt"].is_a?(Integer) &&
        valid_site?(@ticket["site"]) && @ticket["path"].is_a?(String) && @ticket["path"].match?(%r{\A/[!-~]{0,8191}\z}) &&
        safe_fields?(@ticket["fields"])
    end

    def hex?(text, length)
      text.is_a?(String) && text.bytesize == length && text.match?(/\A[a-f0-9]+\z/)
    end

    def valid_site?(site)
      site.is_a?(String) && site.bytesize <= 263 && site.match?(%r{\Ahttps://(?:[a-z0-9.-]+|\[[a-f0-9:.]+\])\z})
    end

    def safe_fields?(fields)
      fields.is_a?(Array) && fields.size <= 1024 && fields.to_json.bytesize <= 100_000 && fields.all? do |row|
        row.is_a?(Array) && row.size == 2 && row.all? { |text| text.is_a?(String) } &&
          (!SECRET_NAME.match?(row.first) || row.last == "[withheld]")
      end
    end
end
