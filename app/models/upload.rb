# A file on the agent's computer that a call names (Tool.reads_files), read by
# the sidecar and handed over before the call reaches Rails (agent/attachments.mjs),
# so a person approves the very bytes that go. Held until the call uses it, or
# for as long as a call can wait, then swept (UploadSweepJob).
class Upload < ApplicationRecord
  class TooLarge < StandardError; end

  KEEP = Invocation::WAIT + 1.hour

  belongs_to :conversation
  has_one_attached :file

  validates :path, presence: true, length: { maximum: 1_024 }

  # Keeps the bytes for one path of one call, in place of any read before (a
  # call replayed after a restart reads its files again). Until it runs, a
  # changed file shows on the card, or voids the person's approval
  # (Invocation#changed_since_approved?). Once it runs, it keeps what it had.
  def self.store(conversation, task_id:, call_id:, path:, bytes:, each:, total:)
    raise TooLarge, "over #{each} bytes" if bytes.bytesize > each
    transaction do
      return if conversation.invocations.where(task_id: task_id, call_id: call_id).where.not(state: %w[ awaiting_person approved ]).exists?
      same_call = conversation.uploads.where(task_id: task_id, call_id: call_id)
      others = same_call.where.not(path: path).includes(file_attachment: :blob).sum { it.file.byte_size }
      raise TooLarge, "over #{total} bytes in all" if others + bytes.bytesize > total
      same_call.find_by(path: path)&.destroy!
      same_call.create!(path: path, sha256: Digest::SHA256.hexdigest(bytes),
        file: { io: StringIO.new(bytes), filename: File.basename(path), content_type: "application/octet-stream", identify: false })
    end
  end

  def name = file.filename.to_s
  def size = file.byte_size
end
