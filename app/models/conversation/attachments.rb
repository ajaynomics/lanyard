# Files a person attaches in the thread other than pictures, which go to the
# model to look at: a PDF, a document, a spreadsheet. Each is kept with the
# send (Conversation::Submission#files) and then its message (Message#files),
# saved on the agent's computer (Conversation::Handover), and named in the
# words the agent reads with where it was saved, so the agent opens it there.
class Conversation::Attachments
  TASK = "composer"
  HEADING = "The person attached these files to this message:"

  Attached = Data.define(:name, :type, :bytes) do
    def digest = { name: name, type: type, digest: Digest::SHA256.hexdigest(bytes) }
  end

  def initialize(conversation, uploads, request_id:)
    @conversation, @request_id = conversation, request_id
    refuse "Attach up to #{Conversation::FILES_PER_MESSAGE} files to one message." if uploads.size > Conversation::FILES_PER_MESSAGE
    @files = uploads.map { read(it) }
  end

  def any? = @files.any?
  def digests = @files.map(&:digest)

  # Each file, with where it was saved, after the person's words: for the
  # agent, not for the bubble (Message#said).
  def note
    return "" if @files.none?
    handover = Conversation::Handover.new(@conversation, task: TASK, call_id: "message-#{Digest::SHA256.hexdigest(@request_id).first(32)}")
    "\n\n<attached_files>\n#{HEADING}\n#{handover.lines(@files).join("\n")}\n</attached_files>"
  end

  def attach_to(record)
    @files.each { record.files.attach(io: StringIO.new(it.bytes), filename: it.name, content_type: it.type, identify: false) }
  end

  private
    def read(upload)
      name = Conversation::Handover.plain(upload.original_filename).presence || "file"
      limit = ActiveSupport::NumberHelper.number_to_human_size(Conversation::FILE_BYTES)
      refuse "#{name} is over #{limit}: each file must be #{limit} or smaller." if upload.size > Conversation::FILE_BYTES
      upload.rewind
      bytes = upload.read.b
      # What the bytes are, refined by the name, rather than what the browser called them.
      type = Marcel::MimeType.for(StringIO.new(bytes), name: name, declared_type: upload.content_type)
      Attached.new(name: name, type: type, bytes: bytes)
    ensure
      upload.rewind
    end

    def refuse(reason) = raise(Conversation::FilesRefused, reason)
end
