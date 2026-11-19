# The copy's Active Storage files attached to a record that came: a message's
# pictures, a card's held files, an upload. Each comes into this install's
# storage under a key of its own, and its checksum is the one recorded there.
# Variants are made again when asked for.
class Workspace::Import::Files
  NAME = "active_storage_attachments"

  def initialize(run)
    @run = run
    @blobs = {}
  end

  def copy
    @run.ids(NAME)
    @run.source.each(NAME) do |row|
      next @run.leave(NAME, "attached to a record that stays in the copy") unless (record_id = record_id(row))
      blob = @blobs[row["blob_id"]] ||= blob(@run.source.find("active_storage_blobs", row["blob_id"]))
      # Inserted, not attached: attaching touches the record, which is to stay as it was.
      attachment = { name: row["name"], record_type: row["record_type"], record_id:, blob_id: blob.id, created_at: row["created_at"] }
      @run.ids(NAME)[row["id"]] = ActiveStorage::Attachment.insert!(attachment, returning: :id).rows.dig(0, 0)
    end
  end

  # Each attachment that came, by its id here: what it is attached to, and its file.
  def self.there(run)
    rows = []
    run.source.each(NAME) do |row|
      next unless (id = run.id(NAME, row["id"]))
      blob = run.source.find("active_storage_blobs", row["blob_id"])
      rows << [ id, row["record_type"], run.id(Workspace::Import::Table.for_record_type(row["record_type"]).name, row["record_id"]), row["name"],
                blob["filename"], blob["content_type"], blob["byte_size"], blob["checksum"] ]
    end
    rows
  end

  def self.here(ids)
    ActiveStorage::Attachment.where(id: ids).includes(:blob).map do |attachment|
      blob = attachment.blob
      [ attachment.id, attachment.record_type, attachment.record_id, attachment.name, blob.filename.to_s, blob.content_type, blob.byte_size, blob.checksum ]
    end
  end

  private
    def record_id(row)
      table = Workspace::Import::Table.for_record_type(row["record_type"])
      table && @run.id(table.name, row["record_id"])
    end

    def blob(row)
      blob = @run.source.file(row["key"]).open("rb") do |file|
        ActiveStorage::Blob.create_and_upload!(io: file, filename: row["filename"], content_type: row["content_type"],
          metadata: JSON.parse(row["metadata"].presence || "{}"), identify: false)
      end
      @run.blobs << blob
      raise Workspace::Import::Refused, "#{row["filename"]} (#{row["key"]}) is not the file its record describes" unless blob.checksum == row["checksum"]
      blob
    end
end
