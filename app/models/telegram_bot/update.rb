# One message as Telegram posts it to a bot (TelegramBot#receive): who wrote
# it, in which chat, its words and the files it carries, which are listed for
# the agent to save with telegram_file rather than fetched unasked.
class TelegramBot::Update
  # The kinds of file a message may carry, each with a name and type when Telegram gives none.
  FILES = { "document" => [ "file", "application/octet-stream" ], "audio" => [ "audio", "audio/mpeg" ],
            "video" => [ "video.mp4", "video/mp4" ], "voice" => [ "voice.ogg", "audio/ogg" ],
            "video_note" => [ "video_note.mp4", "video/mp4" ], "animation" => [ "animation.mp4", "video/mp4" ],
            "sticker" => [ "sticker.webp", "image/webp" ] }.freeze

  def initialize(message) = @message = message

  def chat_id = Integer(@message.dig("chat", "id"))
  def message_id = Integer(@message["message_id"])
  def direct? = @message.dig("chat", "type") == "private"
  def chat_name = direct? ? "a direct message" : (@message.dig("chat", "title").presence || "a group").to_s.squish.truncate(TelegramBot::CHAT_NAME)
  def chat_label = direct? ? "#{sender} (direct message)" : chat_name

  def sender
    from = @message["from"].is_a?(Hash) ? @message["from"] : {}
    [ from["first_name"], from["last_name"] ].compact_blank.join(" ").squish.presence || from["username"].presence || "someone"
  end

  def sent_at = (Time.at(Integer(@message["date"])) rescue nil)

  def words = (@message["text"].presence || @message["caption"]).to_s

  def empty? = words.blank? && files.empty?

  # Whether it calls on the bot named username: written to it alone, or in a
  # group naming it (@username, or a link to it for a name Telegram turns
  # into one) or answering one of its own posts. Anything else in a group is
  # people talking among themselves (#189).
  def to?(username)
    return true if direct?
    return false if username.blank?
    mentions?(username) || answers?(username)
  end

  def mentions?(username)
    entities = @message["text"].present? ? @message["entities"] : @message["caption_entities"]
    Array(entities).any? do |entity|
      next false unless entity.is_a?(Hash)
      case entity["type"]
      when "mention" then entity_words(entity).casecmp?("@#{username}")
      when "text_mention" then entity.dig("user", "username").to_s.casecmp?(username)
      else false
      end
    end
  end

  def answers?(username)
    from = @message.dig("reply_to_message", "from")
    from.is_a?(Hash) && from["is_bot"] == true && from["username"].to_s.casecmp?(username)
  end

  def text
    return words if files.empty?
    listed = files.map { "- #{it[:name]} (#{it[:type]}, #{size(it[:size])}), file id #{it[:id]}" }
    [ words.presence, "Attached, not yet saved:\n#{listed.join("\n")}\nTo save one on your computer, use telegram_file with its file id." ].compact.join("\n\n")
  end

  # Each file it carries, the largest size of a photo only.
  def files
    @files ||= begin
      found = FILES.filter_map do |kind, (name, type)|
        file = @message[kind]
        described(file, name, type) if file.is_a?(Hash)
      end
      photo = Array(@message["photo"]).select { it.is_a?(Hash) }.max_by { it["file_size"].to_i }
      found.unshift(described(photo, "photo.jpg", "image/jpeg")) if photo
      found.compact
    end
  end

  private
    def described(file, name, type)
      id = file["file_id"].to_s
      return unless id.match?(Tool::TelegramFile::FILE_ID)
      { id: id, name: DurableAssistants::Google.safe_name(file["file_name"].presence || name), type: file["mime_type"].presence || type, size: file["file_size"].to_i }
    end

    def size(bytes) = ActiveSupport::NumberHelper.number_to_human_size(bytes)

    # Telegram counts an entity's offset and length in UTF-16 units, so an emoji before it counts two.
    def entity_words(entity)
      offset, length = Integer(entity["offset"], exception: false), Integer(entity["length"], exception: false)
      return "" unless offset && length && offset >= 0 && length >= 0
      words.encode(Encoding::UTF_16LE).byteslice(offset * 2, length * 2).to_s.force_encoding(Encoding::UTF_16LE)
        .encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    rescue EncodingError
      ""
    end
end
