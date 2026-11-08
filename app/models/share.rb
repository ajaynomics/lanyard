# What the phone's Share sheet handed the installed app (the manifest's
# share_target): words, a link, pictures. It sends nothing by itself. It
# waits here while the person picks an agent, then fills that agent's
# composer, and goes once the message is sent (SubmissionsController) or,
# if it never is, after a day (ShareSweepJob).
#
# A record rather than loose blobs: a share POST arrives before the page
# that sends it, so its pictures must outlive one request, and an Active
# Storage blob has no owner. A row of the person's owns them, so only that
# person reaches them, and destroying it purges them.
class Share < ApplicationRecord
  KEEP = 1.day
  # Below SubmissionsController's limit on a message's words.
  TEXT_BYTES = 60_000

  belongs_to :user
  has_many_attached :files

  # The sheet's three fields as one message: a page's title, then the words
  # and the link, each once (Android often sends the link as the words).
  def self.text_from(title: nil, text: nil, url: nil)
    words = text.to_s.strip
    parts = [ (title.to_s.strip unless words.include?(title.to_s.strip)), words, (url.to_s.strip unless words.include?(url.to_s.strip)) ]
    parts.compact_blank.join("\n").byteslice(0, TEXT_BYTES).scrub("")
  end

  # Keeps the files a message can carry, under the composer's own limits
  # (Conversation::IMAGE_TYPES, IMAGE_BYTES, IMAGES_PER_MESSAGE), and says,
  # for each one it cannot, why.
  def stage(uploads)
    uploads.filter_map do |upload|
      name = upload.original_filename.to_s.presence || "A file"
      # What the bytes are, not what the phone called them, as the composer's own check does.
      type = Marcel::MimeType.for(upload.tempfile)
      if !Conversation::IMAGE_TYPES.key?(type) then "#{name} wasn't added: only pictures can be sent to an agent."
      elsif upload.size > Conversation::IMAGE_BYTES then "#{name} wasn't added: each picture must be 5 MB or smaller."
      elsif files.size >= Conversation::IMAGES_PER_MESSAGE then "#{name} wasn't added: a message can carry up to #{Conversation::IMAGES_PER_MESSAGE} pictures."
      else
        upload.rewind
        files.attach(io: upload.tempfile, filename: name, content_type: type)
        nil
      end
    end
  end

  def empty? = text.blank? && files.none?
end
