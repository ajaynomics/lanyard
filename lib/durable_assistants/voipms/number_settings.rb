module DurableAssistants::Voipms
  class NumberSettings
    # setSMS replaces the whole record, under names different from getDIDsInfo.
    SMS_FIELDS = {
      enable: "sms_enabled", email_enabled: "sms_email_enabled", email_address: "sms_email",
      sms_forward_enable: "sms_forward_enabled", sms_forward: "sms_forward",
      url_callback_enable: "sms_url_callback_enabled", url_callback: "sms_url_callback", url_callback_retry: "sms_url_callback_retry",
      dialmode: "dialmode", webhook_enable: "webhook_enabled", webhook: "webhook",
      smpp_enabled: "smpp_enabled", smpp_url: "smpp_url", smpp_user: "smpp_user"
    }.freeze
    MAILBOX_FIELDS = %w[ mailbox name password skip_password attach_message delete_message say_time timezone say_callerid play_instructions language ].freeze
    SMS_CHANGES = %i[ sms_forward sms_email ].freeze

    # Only the replacement closure holds the fields we must not show or store.
    Change = Data.define(:number, :mailbox, :before, :write) do
      def apply = write.call
    end

    def initialize(request)
      @request = request
    end

    def list
      dids.map do |did|
        { number: text(did["did"]), routing: text(did["routing"]), voicemail: mailbox_id(did),
          sms_enabled: enabled?(did["sms_enabled"]), sms_forward_enabled: enabled?(did["sms_forward_enabled"]), sms_forward: text(did["sms_forward"]),
          sms_email_enabled: enabled?(did["sms_email_enabled"]), sms_email: text(did["sms_email"]) }
      end
    end

    def read(number)
      did = find_did(number)
      id = mailbox_id(did)
      box = find_mailbox(id) if id
      { number: number, routing: text(did["routing"]), sms: {
          enabled: enabled?(did["sms_enabled"]), forward_enabled: enabled?(did["sms_forward_enabled"]), forward: text(did["sms_forward"]),
          email_enabled: enabled?(did["sms_email_enabled"]), email: text(did["sms_email"]),
          url_callback_enabled: enabled?(did["sms_url_callback_enabled"]), webhook_enabled: enabled?(did["webhook_enabled"]),
          smpp_enabled: enabled?(did["smpp_enabled"])
        }, voicemail: box && { mailbox: id, email: text(box["email"]), attach_message: enabled?(box["attach_message"]),
                              email_attachment_format: text(box["email_attachment_format"]) } }
    end

    def prepare(number, requested)
      did = find_did(number)
      sms = requested.slice(*SMS_CHANGES)
      sms_form = replacement_sms(did, sms) if sms.any?
      if requested.key?(:voicemail_email)
        id = mailbox_id(did) or raise Error, "This number has no voicemail mailbox. Nothing was changed."
        refuse_shared(id, number)
        box = find_mailbox(id)
        voicemail_form = replacement_voicemail(box, requested.fetch(:voicemail_email))
      end
      before = values(requested.keys, did:, box:)
      Change.new(number:, mailbox: id, before:, write: -> {
        apply(number, before, sms:, sms_form:, voicemail_form:, id:)
      })
    end

    private
      def dids(**fields) = rows("getDIDsInfo", "dids", **fields)

      def find_did(number)
        matching = dids(did: number).select { it["did"].to_s == number }
        raise Error, "That phone number is not on this voip.ms account." if matching.empty?
        raise Error, "voip.ms returned more than one entry for this number." if matching.many?
        matching.sole
      end

      def mailbox_id(did) = text(did["voicemail"]).presence&.then { it unless it == "0" }

      # A mailbox's email is the mailbox's, not the number's: changing it for
      # one number would change it for every other number using that box.
      def refuse_shared(id, number)
        if dids.any? { it["did"].to_s != number && mailbox_id(it) == id }
          raise Error, "This mailbox also takes voicemail for another number. Nothing was changed."
        end
      end

      def find_mailbox(id)
        matching = rows("getVoicemails", "voicemails", mailbox: id).select { it["mailbox"].to_s == id }
        raise Error, "voip.ms did not return one matching voicemail mailbox." unless matching.one?
        matching.sole
      end

      def rows(method, key, **fields)
        entries = @request.call(method, **fields)[key]
        raise Error, "voip.ms returned an unreadable settings list." unless entries.is_a?(Array) && entries.all?(Hash)
        entries
      end

      def enabled?(value) = text(value) == "1"
      def scalar?(value) = value.is_a?(String) || value.is_a?(Numeric)

      def text(value)
        value.to_s if scalar?(value)
      end

      def replacement_sms(did, changes)
        missing = SMS_FIELDS.values.reject { scalar?(did[it]) }
        raise Error, "voip.ms returned incomplete SMS settings (missing #{missing.to_sentence}). Nothing was changed." if missing.any?
        # Its password is not readable, so a replacement would wipe it.
        raise Error, "SMPP is enabled or could not be confirmed off. Nothing was changed." unless did["smpp_enabled"].to_s == "0"
        form = SMS_FIELDS.transform_values { did.fetch(it) }
        if changes.key?(:sms_forward)
          form[:sms_forward] = changes.fetch(:sms_forward)
          form[:sms_forward_enable] = flag(form[:sms_forward])
        end
        if changes.key?(:sms_email)
          form[:email_address] = changes.fetch(:sms_email)
          form[:email_enabled] = flag(form[:email_address])
        end
        form
      end

      def replacement_voicemail(box, email)
        unless MAILBOX_FIELDS.all? { scalar?(box[it]) }
          raise Error, "voip.ms returned incomplete voicemail settings. Nothing was changed."
        end
        box.slice(*MAILBOX_FIELDS).merge("email" => email).tap do |form|
          if scalar?(box["email_attachment_format"])
            form["email_attachment_format"] = box["email_attachment_format"]
          elsif box["email_attachment_format"] != nil
            raise Error, "voip.ms returned unreadable voicemail attachment settings. Nothing was changed."
          end
        end
      end

      def flag(value) = value.empty? ? "0" : "1"

      def values(fields, did: nil, box: nil)
        fields.index_with do |field|
          case field
          when :sms_forward, :sms_email then enabled?(did["#{field}_enabled"]) ? text(did[field.to_s]).to_s : ""
          when :voicemail_email then text(box["email"]).to_s
          end
        end
      end

      def apply(number, before, sms:, sms_form:, voicemail_form:, id:)
        result = { number: number }
        warnings = []
        if sms_form
          @request.call("setSMS", did: number, **sms_form)
          verify(result, warnings, before, sms) do
            did = find_did(number)
            actual = values(sms.keys, did:)
            mismatches = sms.keys.reject { did["#{it}_enabled"].to_s == flag(sms.fetch(it)) && actual[it] == sms[it] }
            [ actual, mismatches ]
          end
        end
        if voicemail_form
          @request.call("setVoicemail", **voicemail_form)
          verify(result, warnings, before, { voicemail_email: voicemail_form.fetch("email") }) do |expected|
            actual = values(expected.keys, box: find_mailbox(id))
            [ actual, expected.keys.reject { actual[it] == expected[it] } ]
          end
        end
        result[:warning] = warnings.join(" ") if warnings.any?
        result
      rescue Error => error
        raise if result.size == 1
        result.merge(warning: [ *warnings, "Could not complete the voicemail email change: #{error.message}" ].join(" "))
      end

      def verify(result, warnings, before, expected)
        actual, mismatches = yield expected
        warnings << "#{mismatches.to_sentence} did not match the request when checked with voip.ms." if mismatches.any?
        expected.each_key { result[it] = { before: before.fetch(it), after: actual.fetch(it) } }
      rescue Error => error
        warnings << "Could not verify #{expected.keys.to_sentence} after the write: #{error.message}"
        expected.each_key { result[it] = { before: before.fetch(it), after: nil } }
      end
  end
end
