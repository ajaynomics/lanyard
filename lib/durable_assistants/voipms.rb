require "net/http"
require "uri"
require "zlib"

module DurableAssistants
  # The API password is the whole account's (docs/phone.md). This is the only
  # code that holds it, from the install or from its workspace's vault entry
  # for each request. It only asks the provider for the operations declared here.
  module Voipms
    URL = URI("https://voip.ms/api/v1/rest.php")
    METHODS = %w[ sendSMS sendMMS getSMS getMMS getDIDsInfo setSMS getVoicemails setVoicemail getRecordings setRecording getRecordingFile ].freeze
    SMS_LIMIT = 160 # characters; longer goes as one MMS, up to MMS_LIMIT
    MMS_LIMIT = 2048
    TIMEOUT = 15 # seconds to connect, and to answer a lookup
    # voip.ms has answered a send after 17 to 19 seconds, having sent it.
    SEND_TIMEOUT = 45
    # Its clock and ours may differ; a match must still be the same words, from and to the same numbers.
    CLOCK_SLACK = 2.minutes
    TRANSPORT_ERRORS = [ Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError,
                         Net::ProtocolError, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Zlib::Error ].freeze
    private_constant :TRANSPORT_ERRORS

    # A syntactically valid status can still echo a credential. Codes from the
    # ecliptical/voip-ms client’s status catalog (retrieved 2026-11-22) are always
    # named; others only when they share nothing with the credentials (Error.response):
    # https://github.com/ecliptical/voip-ms/blob/e3e65e13046bf2778b8a240195e2102fc40eb92e/tools/api-statuses.json
    KNOWN_REFUSAL_STATUSES = %w[
      Invalid_threshold Unable_to_purchase account_with_dids api_limit_exceeded api_not_enabled
      can_have_only_one_profile_without_pin cancel_failed conference_member_relation_not_found did_in_use
      did_limit_reached duplicated_name duplicated_pin e911_disabled e911_pending error_deleting_msg
      error_moving_msg exceeds_file_size existing_did forwards_exceeded handoff_rate_limited invalid_account
      invalid_address invalid_admin invalid_agent_ring_timeout invalid_ai_agent invalid_allowedcodecs
      invalid_announce_join_leave invalid_announce_only_user invalid_announce_position_frequency
      invalid_announce_round_seconds invalid_announce_user_count invalid_area_code invalid_attach_file
      invalid_attachid invalid_attachmessage invalid_authtype invalid_authtype_h323 invalid_authtype_iax2
      invalid_balancemanagement invalid_base_recording invalid_billingtype invalid_call_type
      invalid_callback invalid_callback_enable invalid_callback_retry invalid_callerid
      invalid_callerid_override invalid_calleridprefix invalid_callhunting invalid_callparking
      invalid_callrecording invalid_canada_routing invalid_carrier invalid_charge invalid_city
      invalid_client invalid_cnam invalid_codec invalid_conference invalid_contact invalid_country
      invalid_countryid invalid_credentials invalid_date invalid_date_from invalid_daterange
      invalid_datetime invalid_dayrange invalid_delay_before invalid_deletemessage invalid_description
      invalid_destination invalid_destination_folder invalid_devicetype invalid_dialtime invalid_did
      invalid_digit_timeout invalid_digits invalid_disa invalid_diversion_header invalid_drop_silence
      invalid_dst invalid_dtmf_digits invalid_dtmfmode invalid_email invalid_email_attachment_format
      invalid_email_enable invalid_enable_ip_restriction invalid_enable_pop_restriction invalid_endhour
      invalid_endminute invalid_extension invalid_extension_length invalid_extension_prefix
      invalid_extensions invalid_failover_header invalid_fax_id invalid_file invalid_filter
      invalid_firstname invalid_foc_enddate invalid_foc_startdate invalid_folder invalid_folder_id
      invalid_forward_enable invalid_forwarding invalid_forwarding_did invalid_frequency_announcement
      invalid_from_number invalid_fullname invalid_id invalid_if_announce_position_enabled_report_e
      invalid_internaldialtime invalid_internalvoicemail invalid_internationalroute invalid_invoice_type
      invalid_ip invalid_ip_auth invalid_ip_iax2 invalid_ivr invalid_jitter_buffer invalid_join_announcement
      invalid_join_empty_type invalid_language invalid_lastname invalid_listened invalid_location
      invalid_lockinternational invalid_mailbox invalid_max_expiry invalid_maximum_callers
      invalid_maximum_wait_time invalid_member invalid_member_delay invalid_message_num invalid_method
      invalid_minute invalid_mixed_numbers invalid_monthly invalid_musiconhold invalid_name invalid_nat
      invalid_note invalid_number invalid_number_canadian invalid_number_exist invalid_number_fax
      invalid_number_porttype invalid_number_us invalid_numbermembers invalid_order invalid_package
      invalid_password invalid_password_auth invalid_password_ilegal_characters
      invalid_password_lessthan_8characters_long invalid_password_missing_lowercase
      invalid_password_missing_number invalid_password_missing_uppercase invalid_pause invalid_payment
      invalid_phonebook invalid_phonenumber invalid_pin invalid_pin_number invalid_playinstructions
      invalid_pop_restriction invalid_port_status invalid_portingid invalid_porttype invalid_priority
      invalid_priority_weight invalid_protocol invalid_provider_account invalid_provider_name
      invalid_province invalid_quantity invalid_query invalid_queue invalid_quiet invalid_record_calls
      invalid_recording invalid_recording_sound_error_menu invalid_recording_sound_get_pin
      invalid_recording_sound_has_joined invalid_recording_sound_has_left
      invalid_recording_sound_invalid_pin invalid_recording_sound_join invalid_recording_sound_kicked
      invalid_recording_sound_leave invalid_recording_sound_locked invalid_recording_sound_locked_now
      invalid_recording_sound_muted invalid_recording_sound_only_one invalid_recording_sound_only_person
      invalid_recording_sound_other_in_party invalid_recording_sound_participants_muted
      invalid_recording_sound_participants_unmuted invalid_recording_sound_place_into_conference
      invalid_recording_sound_there_are invalid_recording_sound_unlocked_now invalid_recording_sound_unmuted
      invalid_report_hold_time_agent invalid_resellerclient invalid_resellernextbilling
      invalid_resellerpackage invalid_response_timeout invalid_retry_timer invalid_ring_inuse
      invalid_ringgroup invalid_route invalid_routing_header invalid_rtp_hold_timeout invalid_rtp_timeout
      invalid_saycallerid invalid_saytime invalid_security_code invalid_serverpop invalid_setup
      invalid_silence_threshold invalid_sip_traffic invalid_sipuri invalid_skippassword
      invalid_smpp_password invalid_smpp_url invalid_smpp_username invalid_sms invalid_sms_forward
      invalid_snn invalid_speed_dial invalid_start_muted invalid_starthour invalid_startminute invalid_state
      invalid_statement_name invalid_strategy invalid_street_name invalid_street_number
      invalid_talk_detection invalid_talking_threshold invalid_tfnumber_porttype
      invalid_thankyou_for_your_patience invalid_timecondition invalid_timeout invalid_timerange
      invalid_timezone invalid_to_number invalid_transcription_email invalid_transcription_format
      invalid_transcription_locale invalid_transcription_redaction invalid_transcription_sentiment
      invalid_transcription_summary invalid_type invalid_urgent invalid_username invalid_voice_announcement
      invalid_voicemailsetup invalid_weekdayend invalid_weekdaystart invalid_wrapup_time invalid_zip
      ip_not_enabled limit_reached location_already_exists location_linked_to_subaccount location_not_found
      max_phonebook member_already_included members_exceeded message_empty message_not_found
      method_maintenance mismatch_email_confirm mismatch_password_confirm missing_account missing_address
      missing_agent_ring_timeout missing_ai_agent missing_allowedcodecs missing_attachmessage
      missing_authtype missing_balancemanagement missing_billingtype missing_callback missing_callerid
      missing_callhunting missing_callparking missing_callrecording missing_carrier missing_charge
      missing_choices missing_city missing_client missing_cnam missing_codec missing_conference
      missing_country missing_countryid missing_credentials missing_datetime missing_delay_before
      missing_deletemessage missing_description missing_devicetype missing_dialtime missing_did
      missing_digit_timeout missing_digits missing_disa missing_dtmfmode missing_email missing_email_confirm
      missing_enable missing_endhour missing_endminute missing_failover_busy missing_failover_noanswer
      missing_failover_unreachable missing_file missing_filter missing_firstname missing_folder
      missing_forwarding missing_from_date missing_fullname missing_id
      missing_if_announce_position_enabled_report_e missing_internationalroute missing_ip missing_ip_h323
      missing_ip_restriction missing_ivr missing_join_when_empty missing_language missing_lastname
      missing_leave_when_empty missing_length missing_listened missing_location missing_location_name
      missing_lockinternational missing_mailbox missing_member missing_members missing_message_num
      missing_method missing_minute missing_monthly missing_musiconhold missing_name missing_nat
      missing_number missing_numbers missing_package missing_params missing_password
      missing_password_confirm missing_payment missing_phonebook missing_phonenumber missing_pin
      missing_playinstructions missing_pop_restriction missing_priority missing_priority_weight
      missing_protocol missing_province missing_query missing_recording missing_report_hold_time_agent
      missing_resellerclient missing_resellerpackage missing_response_timeout missing_ring_inuse
      missing_ring_strategy missing_ringgroup missing_route missing_routing missing_saycallerid
      missing_saytime missing_serverpop missing_setup missing_sipuri missing_skippassword missing_sms
      missing_speed_dial missing_start missing_starthour missing_startminute missing_state
      missing_street_name missing_street_number missing_thankyou_for_your_patience missing_timecondition
      missing_timeout missing_timezone missing_to_date missing_transcription_email
      missing_transcription_locale missing_type missing_urgent missing_uri missing_username
      missing_voicemailsetup missing_weekdayend missing_weekdaystart missing_zip moving_fail name_toolong
      no_account no_attachments no_base64file no_callback no_callhunting no_callparking no_callstatus no_cdr
      no_change_billingtype no_client no_conference no_did no_disa no_filter no_forwarding no_ivr no_mailbox
      no_member no_message no_messages no_numbers no_package no_phonebook no_provision no_provision_update
      no_queue no_rate no_recording no_ringgroup no_sequences no_sipuri no_sms no_timecondition
      non_sufficient_funds note_toolong order_failed problem_sending_mail provider_outofservice
      recording_in_use_caller_id_filtering recording_in_use_caller_timecondition recording_in_use_did
      recording_in_use_ivr recording_in_use_queue repeated_ip reserved_ip
      rtp_timeout_greater_than_rtp_hold_timeout same_did_billingtype sent_fail sipuri_in_phonebook
      sms_apply_regulations sms_failed sms_toolong sms_wait_message tls_error unavailable_info
      unsifficient_stock used_description used_email used_extension used_extension_in_location used_filter
      used_ip used_name used_number used_password used_speed_dial used_username weak_password
    ].each(&:freeze).freeze
    private_constant :KNOWN_REFUSAL_STATUSES

    # A send that may have gone stays separate from an Error. Its caller may
    # look for the text but must never submit it again.
    class Unconfirmed < StandardError
      def initialize(attempt:, readback: nil)
        super("Delivery is unknown. Send: #{attempt.diagnostic}. Readback: #{readback&.diagnostic || 'no matching text was listed'}.")
      end
    end

    # A workspace's own account (Workspace#voipms_account): the vault entry
    # holding its API username and password, read as `reader`, one of its
    # agents. Holds the entry's name, never what is in it.
    Account = Data.define(:vault_entry, :reader) do
      def inspect = "#<Voipms::Account>"
      alias_method :to_s, :inspect
    end

    def self.setting(key) = DurableAssistants.config(:voipms, key).presence

    # A workspace's own account needs none of the install's.
    def self.configured?(account = nil) = account.present? || (setting(:username).present? && setting(:password).present?)

    def self.number_settings(account:)
      NumberSettings.new(->(method, **fields) { request(method, account:, **fields) })
    end

    def self.greetings(account:)
      Greetings.new(->(method, **fields) { request(method, account:, **fields) })
    end

    # One text from `from` to `to`, both ten digits, through `account`, or the
    # install's without one. voip.ms's id for it.
    def self.send_text(from:, to:, body:, account: nil)
      kind = body.length <= SMS_LIMIT ? "SMS" : "MMS"
      started = Time.current
      answer = request("send#{kind}", account:, read_timeout: SEND_TIMEOUT, did: from, dst: to, message: body)
      answer["sms"] || answer["mms"]
    rescue Error => error
      raise unless error.outcome_unknown?

      found = begin
        sent_id(from: from, to: to, body: body, since: started, account: account)
      rescue Error => readback
        raise Unconfirmed.new(attempt: error, readback:), cause: nil
      end
      found || raise(Unconfirmed.new(attempt: error), cause: nil)
    end

    # The id of the text `from` sent `to` with these words since `since`, as
    # voip.ms lists it (among MMS for a long one), asked of the account that
    # sent it; nil when it doesn't. An Error when the list can't be had, which
    # says nothing either way.
    def self.sent_id(from:, to:, body:, since:, account: nil)
      method = body.length <= SMS_LIMIT ? "getSMS" : "getMMS"
      answer = request(method, account:, nothing: %w[ no_sms no_mms ], did: from, contact: to, type: 0, timezone: 0, limit: 50,
        from: (since - 1.day).utc.to_date.iso8601, to: 1.day.from_now.utc.to_date.iso8601)
      found = Array(answer["sms"] || answer["mms"]).select do |message|
        message.is_a?(Hash) && message["did"].to_s == from && message["contact"].to_s == to && message["type"].to_s == "0" &&
          message["message"].to_s == body && sent_at(message["date"])&.after?(since - CLOCK_SLACK)
      end
      found.map { it["id"].to_s }.select { it.match?(/\A\d+\z/) }.map(&:to_i).max
    end

    # Asked for in UTC (timezone 0).
    def self.sent_at(date) = (Time.find_zone!("UTC").strptime(date.to_s, "%Y-%m-%d %H:%M:%S") rescue nil)
    private_class_method :sent_at

    # A POST, so the password is never in a URL that something might log. As
    # multipart/form-data: voip.ms answers a URL-encoded form with a SOAP
    # "Bad Request" (HTTP 500), and takes the same fields as multipart.
    # `nothing`: the statuses voip.ms answers a list with when it has none.
    def self.request(method, account:, read_timeout: TIMEOUT, nothing: [], **params)
      raise ArgumentError, "Not an allowed voip.ms operation" unless METHODS.include?(method)

      username, password = credentials(account)
      post = Net::HTTP::Post.new(URL)
      multipart(post, api_username: username, api_password: password, method: method, **params)
      response = perform_post(post, read_timeout:)
      text_send = %w[ sendSMS sendMMS ].include?(method)
      raise Error.server_failure(response.code), cause: nil if text_send && response.is_a?(Net::HTTPServerError)

      answer = parse_response(response.body)
      # Without a usable response, a text may already have gone.
      unless answer.is_a?(Hash)
        raise Error.response(response.code, status: nil, json: false, outcome_unknown: text_send), cause: nil
      end
      return answer if response.is_a?(Net::HTTPSuccess) && answer["status"] == "success"
      return {} if response.is_a?(Net::HTTPSuccess) && nothing.include?(answer["status"])

      raise Error.response(response.code, status: answer["status"], json: true, credentials: [ username, password ]), cause: nil
    end
    private_class_method :request

    def self.perform_post(post, read_timeout:)
      attempted = false
      Net::HTTP.start(URL.host, URL.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout:) do |http|
        attempted = true
        http.request(post)
      end
    rescue *TRANSPORT_ERRORS => problem
      raise Error.transport(problem, attempted: attempted), cause: nil
    end
    private_class_method :perform_post

    def self.parse_response(body)
      JSON.parse(body)
    rescue JSON::ParserError, TypeError
      nil
    end
    private_class_method :parse_response

    # The install's, or read from the vault for this one request and never
    # kept. An entry saved for another site, or for none, is refused, so no
    # other site's password is sent to voip.ms. An Error, before anything is
    # sent, when it can't be read.
    def self.credentials(account)
      if account
        entry = Passbolt.sign_in_by_name(account.reader, account.vault_entry)
        unless entry.host == URL.host || entry.host&.end_with?(".#{URL.host}")
          raise Error.new("The saved sign-in is not for voip.ms. No request was sent.", reason: :credential_origin), cause: nil
        end
        username, password = entry.username, entry.password
      else
        username, password = setting(:username), setting(:password)
      end
      if username.blank? || password.blank?
        raise Error.new("No voip.ms API username and password are configured. No request was sent.", reason: :credentials_missing), cause: nil
      end
      [ username, password ]
    rescue Passbolt::Error => error
      raise Error.new("Could not read the saved voip.ms sign-in. No request was sent.", reason: :credentials_unavailable,
        source_class: error.class), cause: nil
    end
    private_class_method :credentials

    # Built here rather than by Net::HTTP#set_form, which builds it only as it
    # sends, so a test could not read what was sent.
    def self.multipart(post, **fields)
      boundary = SecureRandom.hex(24)
      post.content_type = "multipart/form-data; boundary=#{boundary}"
      post.body = fields.map { |name, value| %(--#{boundary}\r\nContent-Disposition: form-data; name="#{name}"\r\n\r\n#{value}\r\n) }.join.b +
        "--#{boundary}--\r\n"
    end
    private_class_method :multipart
  end
end
