# Mail no person wrote just now: an auto-reply or out-of-office (RFC 3834's
# Auto-Submitted, or the older Precedence and X-Autoreply), a bounce, a
# mailing list, or a sender that takes no replies. A person's mail waits in
# the agent's inbox unless it can't wait; this always waits for its turn to
# end, whatever it says (ReceivedMail#urgency).
module ReceivedMail::Automated
  PRECEDENCE = %w[ bulk junk list auto_reply ].freeze
  SENDER = /\A(?:no-?reply|do-?not-?reply|mailer-daemon|postmaster)(?:[+.\-_]|@)/i

  def automated?
    header_value("Auto-Submitted").then { it && !it.casecmp?("no") } ||
      PRECEDENCE.include?(header_value("Precedence")&.downcase) ||
      %w[ X-Autoreply X-Autorespond List-Id ].any? { header_value(it).present? } ||
      header_value("Return-Path")&.delete("<> ")&.empty? || mail.mime_type == "multipart/report" ||
      mail.from&.first.to_s.match?(SENDER)
  end

  private
    # A header's first value, stripped; "" where it is there but empty, as an empty Return-Path is.
    def header_value(name) = Array(mail.header[name]).first&.value&.to_s&.strip
end
