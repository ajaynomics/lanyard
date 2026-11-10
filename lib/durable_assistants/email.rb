require "net/imap"

module DurableAssistants
  # The install's mail settings (config/mail.yml) and the one catch-all
  # mailbox its agents' mail lands in. Rails has no IMAP ingress, so this
  # reads the box and hands each new message to Action Mailbox; Action
  # Mailbox drops a message it already has, so reading one twice is harmless.
  module Email
    def self.setting(key) = DurableAssistants.config(:mail, key)

    def self.domain = setting(:domain)&.downcase

    # Agents have addresses and send mail only with both a domain and a way out.
    def self.configured? = domain.present? && setting(:smtp_address).present?

    def self.inbox? = configured? && setting(:imap_address).present?

    # What an agent may attach to one message: each file, and all together.
    def self.attachment_bytes = setting(:attachment_limit_mb).to_i.megabytes
    def self.attachments_bytes = setting(:attachments_limit_mb).to_i.megabytes

    # Each message the box holds above `after` (an IMAP UID), oldest first, as
    # [uid, raw message]. A box whose UIDVALIDITY changed numbers its messages
    # afresh, so the caller keeps the two together.
    def self.fetch(after:, validity:)
      imap = Net::IMAP.new(setting(:imap_address), port: setting(:imap_port), ssl: true)
      imap.login(setting(:imap_user_name), setting(:imap_password))
      imap.examine("INBOX")
      current = imap.responses("UIDVALIDITY", &:last)
      after = 0 unless current == validity
      uids = imap.uid_search([ "UID", "#{after + 1}:*" ]).select { it > after }.sort
      uids.each_slice(20) do |slice|
        imap.uid_fetch(slice, "BODY.PEEK[]").each { yield current, it.attr["UID"], it.attr["BODY[]"] }
      end
    ensure
      imap&.disconnect
    end
  end
end
