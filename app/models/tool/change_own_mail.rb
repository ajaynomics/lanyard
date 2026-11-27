# Moves, deletes, marks and labels messages in the agent's own mail account
# (docs/email.md, "Its own mail, changed"), named as read_own_mail gives
# them: the folder and their uids, or one message_id. Its own mailbox is its
# to keep, so nothing asks first: a delete moves the mail to the account's
# Trash, where it can be got back. The tool never empties Trash.
# Only its own sending accounts with an incoming server, as read_own_mail;
# this alone opens a folder to write.
class Tool::ChangeOwnMail < Tool
  include Tool::OwnMail

  ACTIONS = %w[ move delete mark_read mark_unread label unlabel ].freeze

  description "Change messages in your own mail account: move them to another folder, delete them (move to Trash; never purge), " \
    "mark them read or unread, or add or take off a label. Name them as " \
    "read_own_mail gives them: the folder and their uids, or one message_id."
  argument :action, :string, enum: ACTIONS
  argument :account, :string, required: false, max_length: 254, description: "Which of your own addresses; your default when left out."
  argument :folder, :string, required: false, max_length: 100, description: "Where they are: INBOX, Sent, or a folder as listed; INBOX when left out."
  argument :uids, :array, required: false, min_items: 1, max_items: 500, items: { type: "integer", minimum: 1 }, description: "Their uids in that folder."
  argument :message_id, :string, required: false, max_length: 998, description: "Or one message by its Message-ID."
  argument :to, :string, required: false, max_length: 100, description: "For move: the folder to move them to."
  argument :label, :string, required: false, min_length: 1, max_length: 100, description: "For label and unlabel: its name."
  effect :external

  def permitted? = !!agent.mail_account&.reads_sent?

  def call(action:, account: nil, folder: "INBOX", uids: nil, message_id: nil, to: nil, label: nil)
    raise Refusal, "Name the messages: their uids, or a message_id." unless uids || message_id
    raise Refusal, "move needs to: the folder to move them to." if action == "move" && to.blank?
    raise Refusal, "#{action} needs label: its name." if action.end_with?("label") && label.nil?
    own(account).with_mailbox do |imap|
      box = folder_named(imap, folder)
      trash = trash_destination(imap, box) if action == "delete"
      imap.select(box)
      uids ||= [ find(imap, Net::IMAP.decode_utf7(box), message_id) ]
      messages = Agent::MailAccount::Messages.new(imap, uids)
      case action
      when "move" then messages.move(folder_named(imap, to))
      when "delete"
        messages.move(trash)
        to = Net::IMAP.decode_utf7(trash)
      when "label", "unlabel" then messages.public_send(action, label)
      when "mark_read", "mark_unread" then messages.public_send(action)
      end
      { folder: Net::IMAP.decode_utf7(box), uids: uids, done: action, to: (to if action.in?(%w[ move delete ])), label: (label if action.end_with?("label")) }.compact
    end
  rescue Agent::MailAccount::Unreachable, Agent::MailAccount::Messages::Unsupported => problem
    raise Refusal, problem.message
  end

  private
    def trash_destination(imap, box)
      trash = DurableAssistants::Email.trash_folder(imap) or raise Refusal, "This account has no Trash folder, so nothing was deleted."
      raise Refusal, "Mail in Trash stays there; empty it in the mail app." if box == trash
      trash
    end

    def find(imap, folder, message_id)
      imap.uid_search([ "HEADER", "Message-ID", "<#{message_id.delete("<>")}>" ]).max or raise Refusal, "No message #{message_id} in #{folder}."
    end
end
