# One mailbox an agent may reply to through one Gmail connector.
class GmailReplyGrant < ApplicationRecord
  Gmail = DurableAssistants::Google::Gmail
  PARTICIPANTS = %w[ from to cc bcc ].freeze
  MESSAGE_ID = /\A<[^<>\s]+@[^<>\s]+>\z/

  belongs_to :mcp_server
  belongs_to :agent

  encrypts :address, support_unencrypted_data: true
  normalizes :address, with: ->(address) { address.strip.downcase }
  validates :address, format: { with: URI::MailTo::EMAIL_REGEXP }, length: { maximum: 254 }
  validates :agent_id, uniqueness: { scope: :mcp_server_id, message: "already has a reply grant on this connector" }
  validate :same_workspace_gmail
  validate :one_conversation_grant, if: :conversation_scoped?

  def self.for_call(tool, conversation, arguments)
    return unless arguments["thread_id"].present? && tool&.listing&.fetch("name") == "send_message"
    connector, agent = tool.server, conversation.agent
    return unless connector.google == :gmail && connector.workspace_id == agent.workspace_id
    if connector.conversation_id?
      return unless connector.conversation_id == conversation.id && connector.signed_in? && !connector.authorized_by_header?
    end
    grant = connector.gmail_reply_grants.find_by(agent: agent)
    grant if grant&.sole_recipient?(arguments) && !agent.workspace.barred_member(agent, [ grant.address ])
  end

  def conversation_scoped? = mcp_server&.conversation_id?

  def sole_recipient?(arguments)
    fields = arguments.slice("to", "cc", "bcc").symbolize_keys
    return false if fields.values.flatten.any? { it.blank? || it.match?(/[\r\n]/) }
    mail = Gmail.recipient_mail(**fields)
    mail.errors.empty? && (mail.to_addrs.any? || mail.cc_addrs.any?) && mail.destinations.map(&:downcase).uniq == [ address ]
  rescue Mail::Field::ParseError
    false
  end

  def replying(arguments)
    thread_id = arguments.fetch("thread_id")
    thread = McpServer::Google.new(mcp_server).reply_thread(thread_id)
    return unless thread.is_a?(Hash) && thread["id"] == thread_id && thread["messages"].is_a?(Array)
    headers = thread["messages"].map { headers_in(it, thread_id) }
    return if headers.empty? || headers.any?(&:nil?)
    return if conversation_scoped? && uncertain_thread?(thread, headers, arguments)
    last = headers.last
    # Gmail can start a new thread if the subject changes or the reply lacks a Message-ID.
    return unless last["message-id"]&.match?(MESSAGE_ID) && last["subject"].present?
    return if arguments["subject"].present? && subject_of(arguments["subject"]) != subject_of(last["subject"])
    thread["messages"].last if headers.any? { includes_mailbox?(it) }
  rescue DurableAssistants::Google::Error, McpServer::SignInNeeded, Mail::Field::ParseError
    nil
  end

  private
    def headers_in(message, thread_id)
      return unless message.is_a?(Hash) && message["threadId"] == thread_id && message["payload"].is_a?(Hash)
      headers = message.dig("payload", "headers")
      return unless headers.is_a?(Array) && headers.all? { it.is_a?(Hash) && it["name"].is_a?(String) && it["value"].is_a?(String) }
      names = headers.map { it["name"].downcase } & (PARTICIPANTS + %w[ subject message-id references ])
      return unless headers.count { names.include?(it["name"].downcase) } == names.size
      headers.to_h { [ it["name"].downcase, it["value"] ] }
    end

    def includes_mailbox?(headers)
      headers.values_at(*PARTICIPANTS).compact.any? do |value|
        mail = Gmail.recipient_mail(to: value)
        mail.errors.empty? && mail.destinations.any? { it.casecmp?(address) }
      end
    end

    def subject_of(subject) = subject.sub(/\A(?:re:\s*)+/i, "")

    def uncertain_thread?(thread, headers, arguments)
      message_ids = thread["messages"].pluck("id")
      reply_ids = headers.pluck("message-id")
      message_ids.uniq.size != message_ids.size || message_ids.any? { !it.is_a?(String) || it.blank? } ||
        reply_ids.uniq.size != reply_ids.size || reply_ids.any? { !it&.match?(MESSAGE_ID) } ||
        arguments["subject"]&.match?(/[\r\n\x00]/) || headers.any? { !unambiguous_headers?(it) }
    end

    def unambiguous_headers?(headers)
      headers.values.none? { it.match?(/[\r\n\x00]/) } &&
        headers["references"].to_s.split.all? { it.match?(MESSAGE_ID) } &&
        headers.values_at(*PARTICIPANTS).compact.all? { Gmail.recipient_mail(to: it).errors.empty? }
    end

    def same_workspace_gmail
      unless mcp_server&.google == :gmail && mcp_server.workspace_id == agent&.workspace_id &&
          (!conversation_scoped? || mcp_server.conversation&.agent_id == agent_id)
        errors.add(:base, "Choose an agent and a Gmail connector in the same workspace")
      end
    end

    def one_conversation_grant
      if mcp_server.gmail_reply_grants.where.not(id: id).exists?
        errors.add(:base, "This conversation's Gmail connector already has a reply grant")
      end
    end
end
