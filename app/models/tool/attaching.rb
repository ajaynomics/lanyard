# A call that names files on the agent's computer (Tool.reads_files), which
# the sidecar read and handed over before the call (Upload). Its card shows
# each file's name and size, and the approval holds to their bytes
# (Invocation#changed_since_approved?), so a file changed after it was
# approved asks again.
module Tool::Attaching
  ARGUMENT = { "type" => "array", "items" => { "type" => "string", "minLength" => 1, "maxLength" => 1_024 }, "maxItems" => 10,
    "uniqueItems" => true, "description" => "Paths of files on your computer to attach, up to 10." }.freeze

  def self.limits = { each: DurableAssistants::Email.attachment_bytes, total: DurableAssistants::Email.attachments_bytes }

  private
    def attached_paths = attaching_arguments["attachments"].to_a

    # In the order the agent listed them.
    def attached_files = invocation.uploads.where(path: attached_paths).includes(file_attachment: :blob).sort_by { attached_paths.index(it.path) }

    # The first file named that didn't arrive.
    def missing(found) = (attached_paths - found.map(&:path)).first

    def attachments_shown(found) = found.map { "#{it.name} (#{ActiveSupport::NumberHelper.number_to_human_size(it.size)})" }
    def attachments_digest(found) = Digest::SHA256.hexdigest(found.map { [ it.path, it.sha256 ] }.to_json)
end
