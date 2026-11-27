class Agent::GmailInbox::Source
  def initialize(inbox, agent:, connector:)
    @inbox, @agent, @connector = inbox, agent, connector
  end

  def fetch
    return unless @inbox.current_permission?
    return @inbox.pause!("The workspace owner changed.") unless @inbox.enabled_by_owner?
    return @inbox.pause!("Choose a Gmail connector in this workspace.") unless @connector

    McpServer::Google.new(@connector).read_gmail_inbox do |gmail|
      profile = gmail.profile
      unless profile.email == @inbox.mailbox
        next @inbox.pause!("The connector is signed in to a different Gmail account. Sign in to the chosen mailbox, then turn copying back on.")
      end

      read(gmail, baseline: profile.history_id)
    end
  rescue McpServer::SignInNeeded
    pause_for_sign_in
  rescue ActiveRecord::StaleObjectError
    # Someone turned off or changed this inbox while the read was in flight.
  rescue DurableAssistants::Google::Error, DurableAssistants::PiDurable::Client::Error, Conversation::Mismatch,
         Conversation::ImagesRefused, Conversation::Submission::Refused, Mail::Field::ParseError => problem
    Rails.logger.warn("Gmail inbox #{@inbox.id}: not read (#{problem.class.name})")
  end

  private
    def pause_for_sign_in
      @inbox.pause!("Sign in to the Gmail connector, then turn its inbox back on.") if @inbox.current_permission?
    rescue ActiveRecord::StaleObjectError
      # A newer choice belongs to the owner, not the poll that failed.
    end

    def read(gmail, baseline:)
      return @inbox.update!(history_id: baseline) unless @inbox.history_id

      page_token = nil
      loop do
        page = gmail.history(@inbox.history_id, page_token: page_token)
        page.message_ids.each do |id|
          return unless @inbox.current_permission?
          deliver(gmail, id)
        end
        page_token = page.next_page_token
        break @inbox.update!(history_id: page.history_id) unless page_token
      end
    rescue DurableAssistants::Google::GmailInbox::ExpiredHistory
      Rails.logger.warn("Gmail inbox #{@inbox.id}: history expired; starting at the current history ID")
      @inbox.update!(history_id: baseline)
    end

    def deliver(gmail, id)
      receipts = @inbox.receipts.where(mailbox: @inbox.mailbox)
      return if receipts.exists?(gmail_message_id: id)

      message = gmail.raw_message(id)
      return if message.label_ids.include?("SENT")

      mail = Mail.new(message.body)
      return if Array(mail.from).any? { it.casecmp?(@inbox.mailbox) }
      return unless @inbox.current_permission?

      fallback = Digest::SHA256.hexdigest([ @inbox.mailbox, id ].to_json)
      ReceivedMail.new(mail, message_id: mail.message_id.presence || "#{fallback}@gmail.invalid", source: :gmail).deliver_to(@agent)
      receipts.create_or_find_by!(gmail_message_id: id)
    end
end
