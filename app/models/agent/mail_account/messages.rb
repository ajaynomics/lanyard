# Some messages, by UID, in the folder a connection to the agent's own box
# has open to write (SELECT), and what Tool::ChangeOwnMail does to them:
# each one IMAP command, or the plain ones a server without MOVE takes.
class Agent::MailAccount::Messages
  # Without UIDPLUS a server has only EXPUNGE, which takes every message
  # marked deleted, the owner's own included: asked first, nothing changed.
  class Unsupported < StandardError
    def initialize = super("This mail server can't remove only the chosen messages (it has no UIDPLUS), so nothing was changed.")
  end

  def initialize(imap, uids)
    @imap, @uids = imap, uids
  end

  def move(folder)
    return @imap.uid_move(@uids, folder) if @imap.capable?("MOVE")
    expunges_these_alone!
    @imap.uid_copy(@uids, folder)
    delete
  end

  # These alone: UID EXPUNGE leaves any other marked \Deleted.
  def delete
    expunges_these_alone!
    @imap.uid_store(@uids, "+FLAGS", [ :Deleted ])
    @imap.uid_expunge(@uids)
  end

  def mark_read = @imap.uid_store(@uids, "+FLAGS", [ :Seen ])
  def mark_unread = @imap.uid_store(@uids, "-FLAGS", [ :Seen ])

  # Gmail's own labels where it offers them; anywhere else, a keyword.
  def label(name) = @imap.uid_store(@uids, "+#{labels}", [ name ])
  def unlabel(name) = @imap.uid_store(@uids, "-#{labels}", [ name ])

  private
    def expunges_these_alone! = @imap.capable?("UIDPLUS") || raise(Unsupported)

    def labels = @imap.capable?("X-GM-EXT-1") ? "X-GM-LABELS" : "FLAGS"
end
