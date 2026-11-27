require "base64"
require "digest"

module DurableAssistants::Voipms
  class Greetings
    # The mailbox write replaces settings that do not belong to the greeting.
    # Only writable mailbox fields shared by getVoicemails and setVoicemail
    # go back; message counts and reseller account selectors are not settings.
    PRESERVED_FIELDS = %w[
      mailbox name password skip_password email attach_message delete_message say_time
      timezone say_callerid play_instructions language email_attachment_format
      transcription transcription_locale transcription_redaction transcription_summary
      transcription_sentiment transcription_format transcription_delay
    ].freeze

    def initialize(request)
      @request = request
    end

    def recording(id)
      id = identifier!(id)
      row = one(read_recording("getRecordings", id)["recordings"], "value", id)
      name = row["description"]
      raise Error, "voip.ms did not return a recording name." unless readable?(name) && name.is_a?(String) && name.present?
      { id: id, name: name }
    end

    def create_recording(name:, bytes:, approved_sha256:)
      # Hash and encode the same copy; do not reopen a file or re-encode audio.
      audio = bytes.b if bytes.is_a?(String)
      unless audio.present? && approved_sha256.is_a?(String) && approved_sha256.match?(/\A[0-9a-f]{64}\z/) &&
          Digest::SHA256.hexdigest(audio) == approved_sha256
        raise Error, "The recording bytes do not match the approval. Nothing was uploaded."
      end
      unless name.is_a?(String) && name.present? && readable?(name)
        raise Error, "The recording needs a readable name. Nothing was uploaded."
      end
      answer = @request.call("setRecording", name:, file: Base64.strict_encode64(audio))
      identifier!(answer["recording"], error: "voip.ms did not confirm the new recording ID. Check before trying again.")
    end

    def set_unavailable_recording(mailbox:, expected_recording_id:, recording_id:)
      mailbox = identifier!(mailbox)
      expected = identifier!(expected_recording_id, zero: true)
      recording_id = identifier!(recording_id)
      box = one(@request.call("getVoicemails", mailbox:)["voicemails"], "mailbox", mailbox)
      unless identifier(box["unavailable_message_recording"], zero: true) == expected
        raise Error, "The mailbox greeting could not be confirmed unchanged. Nothing was changed."
      end
      unless PRESERVED_FIELDS.all? { readable?(box[it]) } && box["password"].to_s.match?(/\A[0-9]+\z/)
        raise Error, "voip.ms returned incomplete or masked mailbox settings. Nothing was changed."
      end
      if recording_id != expected
        form = box.slice(*PRESERVED_FIELDS).merge("unavailable_message_recording" => recording_id)
        @request.call("setVoicemail", **form)
      end
      recording_id
    end

    private
      def read_recording(method, id)
        raise ArgumentError, "Not a voip.ms recording read" unless %w[ getRecordings getRecordingFile ].include?(method)
        @request.call(method, recording: identifier!(id))
      end

      def one(rows, id_key, id)
        unless rows.is_a?(Array) && rows.all?(Hash)
          raise Error, "voip.ms returned an unreadable list."
        end
        matches = rows.select { identifier(it[id_key]) == id }
        raise Error, "voip.ms did not return one matching entry." unless matches.one?
        matches.sole
      end

      def identifier(value, zero: false)
        return unless value.is_a?(Integer) || value.is_a?(String)
        string = value.to_s
        string if string.match?(/\A(?:0|[1-9][0-9]*)\z/) && (zero || string != "0")
      end

      def identifier!(value, zero: false, error: "A valid voip.ms ID is required.")
        identifier(value, zero:) or raise Error, error
      end

      def readable?(value)
        return true if value.is_a?(Integer)
        value.is_a?(String) && !value.match?(/[[:cntrl:]]/) &&
          !value.strip.match?(/\A(?:[*•]+|\[?(?:hidden|masked|redacted)\]?)\z/i)
      end
  end
end
