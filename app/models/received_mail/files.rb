# The files a message carries: its attachments, and the pictures its body
# shows (inline parts with a name, or with a Content-ID). Each is saved on the
# agent's computer and listed in the message, with where it was saved or,
# plainly, why not (Conversation::Handover). The same message read again
# (from both boxes, or a retry) is listed the same and is not saved twice.
class ReceivedMail::Files
  TASK = "email"

  Attached = Data.define(:name, :type, :bytes)

  def initialize(mail)
    @mail = mail
  end

  # A part that is a file, not the words of the message: one with a name,
  # or a picture its body shows by its Content-ID.
  def self.file?(part)
    !part.multipart? && (part.attachment? || (part.content_id.present? && !part.mime_type.to_s.start_with?("text/")))
  end

  # The lines the message gives its files, saved first where they can be.
  def listing(agent, request_id)
    return "" if files.empty?
    handover = Conversation::Handover.new(agent.conversation, task: TASK, call_id: "mail-#{Digest::SHA256.hexdigest(request_id).first(32)}")
    "Attachments:\n#{handover.lines(files).join("\n")}\n"
  end

  private
    def files
      @files ||= (@mail.multipart? ? @mail.all_parts : [ @mail ]).select { self.class.file?(it) }
        .map { Attached.new(name: name_of(it), type: plain(it.mime_type.presence || "application/octet-stream"), bytes: it.decoded.b) }
    end

    # Its own name, or for a picture known only by its Content-ID, that.
    def name_of(part)
      name = plain(part.filename.to_s)
      return name if name.present?
      base = plain(part.content_id.to_s.delete("<>").split("@").first).presence || "file"
      extension = MiniMime.lookup_by_content_type(part.mime_type.to_s)&.extension
      extension ? "#{base}.#{extension}" : base
    end

    def plain(text) = Conversation::Handover.plain(text)
end
