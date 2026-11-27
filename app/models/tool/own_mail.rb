# What read_own_mail and change_own_mail share: the agent's own sending
# accounts with an incoming server, any other refused by address before a
# connection opens, and a folder by the name the agent knows it by.
module Tool::OwnMail
  private
    def own(address)
      own = agent.mail_accounts.sending.select(&:reads_sent?)
      return agent.mail_account if address.blank?
      own.find { it.address == address.strip.downcase } or
        raise Tool::Refusal, "#{address} is not your own mail account: you can use only #{own.map(&:address).to_sentence}."
    end

    # Sent is the folder the server marks Sent, whatever it is called there.
    def folder_named(imap, folder) = (DurableAssistants::Email.sent_folder(imap) if folder.casecmp?("Sent")) || Net::IMAP.encode_utf7(folder)
end
