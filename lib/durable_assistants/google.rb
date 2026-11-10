require "net/http"
require "uri"

module DurableAssistants
  # Gmail, Google Calendar, Drive, Docs and Chat through their plain REST APIs, with a token a
  # connector's sign-in already holds (McpServer::Google). Google's hosted MCP
  # servers answer only projects enrolled in its Developer Preview; these APIs
  # answer any project that has them switched on, with the same scopes.
  module Google
    TOKEN_URL = URI("https://oauth2.googleapis.com/token")
    GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"
    CALENDAR = "https://www.googleapis.com/calendar/v3"
    DRIVE = "https://www.googleapis.com/drive/v3"
    DOCS = "https://docs.googleapis.com/v1"
    CHAT = "https://chat.googleapis.com/v1"
    TIMEOUT = 30 # seconds
    TEXT_LIMIT = 20_000 # characters of one message's body
    FILE_LIMIT = 25.megabytes # a file saved on the agent's computer

    class Error < StandardError; end
    # The token is no good: renew it, or ask the person to sign in again.
    class Unauthorized < Error; end
    # Google won't renew the sign-in (invalid_grant), or there is nothing to
    # renew it with: only a new sign-in helps.
    class GrantRefused < Unauthorized; end

    # A fresh access token for a refresh token, as Google's token endpoint
    # answers: access_token and expires_in (no new refresh token).
    def self.refresh(client, refresh_token)
      response = Net::HTTP.post_form(TOKEN_URL, { grant_type: "refresh_token", refresh_token: refresh_token,
        client_id: client["client_id"], client_secret: client["client_secret"] }.compact)
      answer = JSON.parse(response.body) rescue {}
      return answer if response.is_a?(Net::HTTPSuccess) && answer["access_token"].present?
      raise GrantRefused, "Google refused to renew the sign-in (#{response.code} #{answer['error']})" if answer["error"] == "invalid_grant"
      raise Error, "Google could not renew the sign-in (#{response.code} #{answer['error']})".squish
    end

    # One call: JSON in and out, or the body as text (raw: true) or as bytes
    # (raw: :bytes), for a file's contents. Google's own message comes back on
    # a refusal, which tells the model what to fix (a bad query, a missing scope).
    def self.request(token, method, url, query: nil, body: nil, raw: false)
      uri = URI(url)
      uri.query = URI.encode_www_form(query.compact) if query.present?
      request = Net::HTTP.const_get(method.to_s.capitalize).new(uri, "Authorization" => "Bearer #{token}", "Accept" => "application/json")
      if body
        request["Content-Type"] = "application/json"
        request.body = body.to_json
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { it.request(request) }
      raise Unauthorized, "Google needs a new sign-in" if response.is_a?(Net::HTTPUnauthorized)
      return response.body.to_s.b if raw == :bytes && response.is_a?(Net::HTTPSuccess)
      return response.body.to_s.dup.force_encoding(Encoding::UTF_8).scrub if raw && response.is_a?(Net::HTTPSuccess)
      answer = response.body.present? ? (JSON.parse(response.body) rescue {}) : {}
      raise Error, "Google refused: #{answer.dig('error', 'message') || response.code}".truncate(500) unless response.is_a?(Net::HTTPSuccess)
      answer
    rescue SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError, IOError => failure
      raise Error, "Could not reach Google: #{failure.class.name.demodulize}"
    end

    # A name that stays one file in one folder on the agent's computer: no
    # folders, no control characters, nothing hidden, not too long, its
    # extension kept (agent/files.mjs keeps the same rule).
    def self.safe_name(name)
      base = name.to_s.unicode_normalize(:nfc).split(%r{[\\/]}).last.to_s
        .gsub(/[\p{Cc}\p{Cf}]/, "").gsub(/[^\p{L}\p{N} ._()+,@-]/, "_").gsub(/\s+/, " ").strip.sub(/\A[.\s]+/, "")
      if base.length > 120
        extension = File.extname(base).then { it.length.between?(2, 10) ? it : "" }
        base = base[0, 120 - extension.length] + extension
      end
      base.presence || "file"
    end

    # What a tool answers about a file the sidecar will save (agent/files.mjs),
    # or why it won't.
    def self.file(name:, type:, size:)
      if size.to_i > FILE_LIMIT then { note: "It is over 25 MB, so it can't be saved or read." }
      else { file: { name: safe_name(name), type: type.to_s, size: size.to_i } }
      end
    end

    module Gmail
      HEADERS = %w[ From To Cc Subject Date ].freeze

      def self.search_threads(token, query:, page_size:, page_token: nil)
        page = Google.request(token, :get, "#{GMAIL}/threads", query: { q: query, maxResults: page_size, pageToken: page_token })
        threads = Array(page["threads"]).map do |thread|
          full = Google.request(token, :get, "#{GMAIL}/threads/#{thread['id']}", query: { format: "metadata", metadataHeaders: HEADERS })
          messages = Array(full["messages"])
          last = messages.last || {}
          { thread_id: thread["id"], subject: header(messages.first, "Subject"), from: header(last, "From"),
            date: header(last, "Date"), snippet: last["snippet"], messages: messages.size,
            unread: messages.any? { Array(it["labelIds"]).include?("UNREAD") }, labels: messages.flat_map { Array(it["labelIds"]) }.uniq }
        end
        { threads: threads, next_page_token: page["nextPageToken"] }.compact
      end

      def self.get_thread(token, thread_id:)
        thread = Google.request(token, :get, "#{GMAIL}/threads/#{escape(thread_id)}", query: { format: "full" })
        { thread_id: thread["id"], messages: Array(thread["messages"]).map { message(it) } }
      end

      def self.get_message(token, message_id:)
        message(Google.request(token, :get, "#{GMAIL}/messages/#{escape(message_id)}", query: { format: "full" }))
      end

      def self.list_labels(token)
        { labels: Array(Google.request(token, :get, "#{GMAIL}/labels")["labels"]).map { { id: it["id"], name: it["name"], type: it["type"] } } }
      end

      def self.list_drafts(token, page_size:, page_token: nil)
        page = Google.request(token, :get, "#{GMAIL}/drafts", query: { maxResults: page_size, pageToken: page_token })
        drafts = Array(page["drafts"]).map do |draft|
          full = Google.request(token, :get, "#{GMAIL}/drafts/#{draft['id']}", query: { format: "metadata" })
          message = full["message"] || {}
          { draft_id: full["id"], thread_id: message["threadId"], to: header(message, "To"), subject: header(message, "Subject"), snippet: message["snippet"] }
        end
        { drafts: drafts, next_page_token: page["nextPageToken"] }.compact
      end

      def self.get_draft(token, draft_id:)
        draft = Google.request(token, :get, "#{GMAIL}/drafts/#{escape(draft_id)}", query: { format: "full" })
        { draft_id: draft["id"], message: message(draft["message"] || {}) }
      end

      # A draft, or one replacing a draft's content (draft_id), as a reply in its thread when thread_id is given.
      def self.save_draft(token, draft_id: nil, **fields)
        raw, thread_id = compose(token, **fields)
        body = { message: { raw: raw, threadId: thread_id }.compact }
        draft = draft_id ? Google.request(token, :put, "#{GMAIL}/drafts/#{escape(draft_id)}", body: body) : Google.request(token, :post, "#{GMAIL}/drafts", body: body)
        { draft_id: draft["id"], message_id: draft.dig("message", "id"), thread_id: draft.dig("message", "threadId") }
      end

      # A draft exactly as it would go out, for the person to approve: whom it
      # reaches, its subject, its whole text and its attachments, and a digest
      # of every byte of it, so the approval can be checked again just before
      # it is sent.
      def self.draft_preview(token, draft_id:)
        raw = Base64.urlsafe_decode64(Google.request(token, :get, "#{GMAIL}/drafts/#{escape(draft_id)}", query: { format: "raw" }).dig("message", "raw").to_s)
        mail = Mail.new(raw)
        body = mail.text_part&.decoded || mail.html_part&.decoded&.then { Rails::HTML5::FullSanitizer.new.sanitize(it).strip } ||
          (mail.body.decoded unless mail.multipart?)
        { "to" => Array(mail[:to]&.formatted), "cc" => Array(mail[:cc]&.formatted), "bcc" => Array(mail[:bcc]&.formatted),
          "subject" => mail.subject.to_s, "body" => body.to_s.force_encoding(Encoding::UTF_8).scrub,
          "attachments" => mail.attachments.map(&:filename), "digest" => Digest::SHA256.hexdigest(raw) }
      end

      def self.send_draft(token, draft_id:)
        sent = Google.request(token, :post, "#{GMAIL}/drafts/send", body: { id: draft_id })
        { sent: true, message_id: sent["id"], thread_id: sent["threadId"] }
      end

      def self.delete_draft(token, draft_id:)
        Google.request(token, :delete, "#{GMAIL}/drafts/#{escape(draft_id)}")
        { deleted: true, draft_id: draft_id }
      end

      def self.send_message(token, **fields)
        raw, thread_id = compose(token, **fields)
        sent = Google.request(token, :post, "#{GMAIL}/messages/send", body: { raw: raw, threadId: thread_id }.compact)
        { sent: true, message_id: sent["id"], thread_id: sent["threadId"] }
      end

      # The message as Gmail takes it (base64url RFC 2822) and its thread. A
      # reply carries In-Reply-To and References, or Gmail starts a new thread
      # in the recipient's mailbox.
      def self.compose(token, to:, subject: nil, body:, cc: nil, bcc: nil, thread_id: nil)
        replying = thread_id && Array(Google.request(token, :get, "#{GMAIL}/threads/#{escape(thread_id)}",
          query: { format: "metadata", metadataHeaders: %w[ Subject Message-ID References ] })["messages"]).last
        mail = Mail.new
        mail.to, mail.cc, mail.bcc = to, cc.presence, bcc.presence
        # Gmail reads Bcc from the message and strips it when it sends; the Mail
        # gem leaves it out of what it encodes unless told to keep it.
        mail[:bcc].include_in_headers = true if mail[:bcc]
        mail.subject = subject.presence || reply_subject(header(replying, "Subject"))
        mail.charset = "UTF-8"
        mail.body = body
        if replying && (id = header(replying, "Message-ID")).present?
          mail.in_reply_to = id
          mail.references = [ header(replying, "References"), id ].compact_blank.join(" ")
        end
        [ Base64.urlsafe_encode64(mail.encoded), thread_id ]
      end

      # An attachment, known by its part's id, which Gmail keeps (its own
      # attachmentId can change from one read of the message to the next).
      def self.attachment(token, message_id:, attachment_id:)
        part = find_part(token, message_id, attachment_id)
        { message_id: message_id, attachment_id: part["partId"], name: part["filename"], type: part["mimeType"], size: part.dig("body", "size").to_i,
          **Google.file(name: part["filename"], type: part["mimeType"], size: part.dig("body", "size")) }
      end

      def self.attachment_bytes(token, message_id:, attachment_id:)
        part = find_part(token, message_id, attachment_id)
        raise Error, "The attachment is over 25 MB." if part.dig("body", "size").to_i > FILE_LIMIT
        data = part.dig("body", "data") ||
          Google.request(token, :get, "#{GMAIL}/messages/#{escape(message_id)}/attachments/#{escape(part.dig('body', 'attachmentId'))}")["data"]
        Base64.urlsafe_decode64(data.to_s)
      end

      def self.find_part(token, message_id, attachment_id)
        payload = Google.request(token, :get, "#{GMAIL}/messages/#{escape(message_id)}", query: { format: "full" })["payload"] || {}
        parts(payload).find { it["filename"].present? && (it["partId"] == attachment_id.to_s || it.dig("body", "attachmentId") == attachment_id.to_s) } or
          raise Error, "That message has no attachment #{attachment_id}; get_message lists each one's attachment_id."
      end

      def self.reply_subject(subject) = subject.to_s.match?(/\Are:/i) ? subject : "Re: #{subject}".strip

      def self.message(message)
        payload = message["payload"] || {}
        { message_id: message["id"], thread_id: message["threadId"], **HEADERS.to_h { [ it.downcase.to_sym, header(message, it) ] }.compact,
          labels: message["labelIds"], text: text(payload).to_s.truncate(TEXT_LIMIT),
          attachments: parts(payload).select { it["filename"].present? }
            .map { { attachment_id: it["partId"], name: it["filename"], type: it["mimeType"], size: it.dig("body", "size") }.compact }.presence }.compact
      end

      def self.header(message, name)
        Array(message&.dig("payload", "headers")).find { it["name"].casecmp?(name) }&.dig("value")
      end

      def self.parts(payload) = [ payload, *Array(payload["parts"]).flat_map { parts(it) } ]

      # Plain text where the message has it, else its HTML without the markup.
      def self.text(payload)
        plain = parts(payload).find { it["mimeType"] == "text/plain" && it["filename"].blank? && it.dig("body", "data") }
        return decode(plain.dig("body", "data")) if plain
        html = parts(payload).find { it["mimeType"] == "text/html" && it.dig("body", "data") }
        Rails::HTML5::FullSanitizer.new.sanitize(decode(html.dig("body", "data"))).gsub(/[ \t]+/, " ").gsub(/\n\s*\n+/, "\n\n").strip if html
      end

      def self.decode(data) = Base64.urlsafe_decode64(data).force_encoding(Encoding::UTF_8).scrub

      def self.escape(id) = ERB::Util.url_encode(id)
    end

    module Calendar
      DATE = /\A\d{4}-\d{2}-\d{2}\z/

      # The signed-in account's address: its primary calendar's id.
      def self.own_address(token) = Google.request(token, :get, "#{CALENDAR}/users/me/calendarList/primary")["id"]

      def self.list_calendars(token)
        calendars = Array(Google.request(token, :get, "#{CALENDAR}/users/me/calendarList")["items"]).map do
          { calendar_id: it["id"], name: it["summaryOverride"] || it["summary"], primary: it["primary"] == true, access: it["accessRole"], time_zone: it["timeZone"] }
        end
        { calendars: calendars }
      end

      def self.list_events(token, calendar_id:, time_min: nil, time_max: nil, query: nil, page_size:, page_token: nil)
        page = Google.request(token, :get, "#{CALENDAR}/calendars/#{escape(calendar_id)}/events",
          query: { timeMin: time_min, timeMax: time_max, q: query, maxResults: page_size, pageToken: page_token, singleEvents: true, orderBy: "startTime" })
        { events: Array(page["items"]).map { event(it, brief: true) }, time_zone: page["timeZone"], next_page_token: page["nextPageToken"] }.compact
      end

      def self.get_event(token, calendar_id:, event_id:)
        event(Google.request(token, :get, "#{CALENDAR}/calendars/#{escape(calendar_id)}/events/#{escape(event_id)}"))
      end

      def self.create_event(token, calendar_id:, send_updates: "none", **fields)
        event(Google.request(token, :post, "#{CALENDAR}/calendars/#{escape(calendar_id)}/events", query: { sendUpdates: send_updates }, body: body(fields)))
      end

      def self.update_event(token, calendar_id:, event_id:, send_updates: "none", **fields)
        event(Google.request(token, :patch, "#{CALENDAR}/calendars/#{escape(calendar_id)}/events/#{escape(event_id)}",
          query: { sendUpdates: send_updates }, body: body(fields)))
      end

      def self.delete_event(token, calendar_id:, event_id:, send_updates: "none")
        Google.request(token, :delete, "#{CALENDAR}/calendars/#{escape(calendar_id)}/events/#{escape(event_id)}", query: { sendUpdates: send_updates })
        { deleted: true, event_id: event_id }
      end

      # The person's own answer to an invitation: their row among the attendees.
      def self.respond_to_event(token, calendar_id:, event_id:, response:, send_updates: "all")
        current = Google.request(token, :get, "#{CALENDAR}/calendars/#{escape(calendar_id)}/events/#{escape(event_id)}")
        attendees = Array(current["attendees"])
        raise Error, "The person isn't invited to that event, so there is nothing to answer." unless attendees.any? { it["self"] }
        attendees = attendees.map { it["self"] ? it.merge("responseStatus" => response) : it }
        update = Google.request(token, :patch, "#{CALENDAR}/calendars/#{escape(calendar_id)}/events/#{escape(event_id)}",
          query: { sendUpdates: send_updates }, body: { attendees: attendees })
        event(update, brief: true)
      end

      # Only what was given, so an update changes just those fields. A start
      # or end that is a date alone makes an all-day event.
      def self.body(fields)
        zone = fields[:time_zone]
        { summary: fields[:summary], location: fields[:location], description: fields[:description],
          start: (time(fields[:start], zone) if fields[:start]), end: (time(fields[:end], zone) if fields[:end]),
          attendees: fields[:attendees]&.map { { email: it } } }.compact
      end

      def self.time(value, zone) = value.match?(DATE) ? { date: value } : { dateTime: value, timeZone: zone }.compact

      def self.event(event, brief: false)
        { event_id: event["id"], summary: event["summary"], start: event.dig("start", "dateTime") || event.dig("start", "date"),
          end: event.dig("end", "dateTime") || event.dig("end", "date"), location: event["location"], status: event["status"],
          organizer: event.dig("organizer", "email"), recurring: event["recurringEventId"].present? || nil,
          attendees: Array(event["attendees"]).map { { email: it["email"], response: it["responseStatus"], you: it["self"] }.compact }.presence,
          description: event["description"]&.truncate(brief ? 500 : TEXT_LIMIT), link: (event["htmlLink"] unless brief) }.compact
      end

      def self.escape(id) = ERB::Util.url_encode(id)
    end

    # Files in Drive: found, read as text, shared. Docs are made and edited
    # through the Docs API (Docs, below).
    module Drive
      FIELDS = "id,name,mimeType,modifiedTime,size,owners(emailAddress),webViewLink".freeze
      READ_LIMIT = 100_000 # characters of one file
      DOWNLOAD_LIMIT = 5.megabytes
      # Google's own files have no bytes of their own: each is exported as text.
      EXPORTS = { "application/vnd.google-apps.document" => { "markdown" => "text/markdown", "text" => "text/plain" },
        "application/vnd.google-apps.spreadsheet" => "text/csv", "application/vnd.google-apps.presentation" => "text/plain" }.freeze
      TEXT = %r{\Atext/|\Aapplication/(json|xml|javascript|x-yaml|yaml|csv)\b}

      # The signed-in account's address.
      def self.own_address(token) = Google.request(token, :get, "#{DRIVE}/about", query: { fields: "user(emailAddress)" }).dig("user", "emailAddress")

      def self.search_files(token, query: nil, page_size:, page_token: nil)
        q = [ "trashed = false", query.presence&.then { "(#{it})" } ].compact.join(" and ")
        page = Google.request(token, :get, "#{DRIVE}/files", query: { q: q, pageSize: page_size, pageToken: page_token, fields: "nextPageToken,files(#{FIELDS})",
          # Drive sorts no full-text search; it ranks those by relevance.
          orderBy: ("modifiedTime desc" unless q.include?("fullText")), supportsAllDrives: true, includeItemsFromAllDrives: true })
        { files: Array(page["files"]).map { file(it) }, next_page_token: page["nextPageToken"] }.compact
      end

      # A file and its words: a Doc as Markdown (or plain text), a Sheet's
      # first sheet as CSV, Slides as text, a text file as it is. Anything else
      # is described, not read.
      def self.read_file(token, file_id:, format: "markdown")
        meta = Google.request(token, :get, "#{DRIVE}/files/#{escape(file_id)}", query: { fields: FIELDS, supportsAllDrives: true })
        type = meta["mimeType"].to_s
        text = if (export = EXPORTS[type])
          export = export.fetch(format.presence || "markdown", export["text"]) if export.is_a?(Hash)
          Google.request(token, :get, "#{DRIVE}/files/#{escape(file_id)}/export", query: { mimeType: export }, raw: true)
        elsif type.match?(TEXT) && meta["size"].to_i <= DOWNLOAD_LIMIT
          Google.request(token, :get, "#{DRIVE}/files/#{escape(file_id)}", query: { alt: "media", supportsAllDrives: true }, raw: true)
        end
        # A PDF is saved on the agent's computer and read there (agent/files.mjs).
        return { **file(meta), **Google.file(name: meta["name"], type: type, size: meta["size"]) } if type == "application/pdf"
        { **file(meta), text: text&.truncate(READ_LIMIT), truncated: (true if text && text.length > READ_LIMIT),
          note: ("This kind of file can't be read as text." unless text) }.compact
      end

      def self.download(token, file_id:)
        meta = Google.request(token, :get, "#{DRIVE}/files/#{escape(file_id)}", query: { fields: "size", supportsAllDrives: true })
        raise Error, "The file is over 25 MB." if meta["size"].to_i > FILE_LIMIT
        Google.request(token, :get, "#{DRIVE}/files/#{escape(file_id)}", query: { alt: "media", supportsAllDrives: true }, raw: :bytes)
      end

      # Who has the file, and how: each permission's id, kind, role and address.
      def self.list_permissions(token, file_id:)
        page = Google.request(token, :get, "#{DRIVE}/files/#{escape(file_id)}/permissions",
          query: { fields: "permissions(id,type,role,emailAddress,domain,displayName)", supportsAllDrives: true })
        { file_id: file_id, permissions: Array(page["permissions"]).map { permission(it) } }
      end

      # A user or group by address, a whole domain, or anyone with the link.
      # Google emails a person or group it shares with unless notify is false.
      def self.share_file(token, file_id:, role:, type: "user", email_address: nil, domain: nil, notify: true, message: nil)
        person = type.in?(%w[ user group ])
        shared = Google.request(token, :post, "#{DRIVE}/files/#{escape(file_id)}/permissions",
          query: { supportsAllDrives: true, sendNotificationEmail: (notify != false if person), emailMessage: (message.presence if person && notify != false),
            fields: "id,type,role,emailAddress,domain,displayName" },
          body: { role: role, type: type, emailAddress: (email_address if person), domain: (domain if type == "domain") }.compact)
        { shared: true, file_id: file_id, **permission(shared) }
      end

      def self.file(file)
        { file_id: file["id"], name: file["name"], type: file["mimeType"], modified: file["modifiedTime"], size: file["size"]&.to_i,
          owners: Array(file["owners"]).map { it["emailAddress"] }.presence, link: file["webViewLink"] }.compact
      end

      def self.permission(it)
        { permission_id: it["id"], type: it["type"], role: it["role"], email_address: it["emailAddress"], domain: it["domain"], name: it["displayName"] }.compact
      end

      def self.escape(id) = ERB::Util.url_encode(id)
    end

    # Google Docs: made, and changed with the Docs API's own edits
    # (documents.batchUpdate). Read through Drive (Drive.read_file).
    module Docs
      def self.create_document(token, title:, text: nil)
        document = Google.request(token, :post, "#{DOCS}/documents", body: { title: title })
        Google.request(token, :post, "#{DOCS}/documents/#{escape(document['documentId'])}:batchUpdate",
          body: { requests: [ { insertText: { location: { index: 1 }, text: text } } ] }) if text.present?
        { document_id: document["documentId"], title: document["title"], link: "https://docs.google.com/document/d/#{document['documentId']}/edit" }
      end

      def self.edit_document(token, document_id:, requests:)
        raise Error, "requests must be a list of the Docs API's edits." unless requests.is_a?(Array) && requests.all?(Hash)
        answer = Google.request(token, :post, "#{DOCS}/documents/#{escape(document_id)}:batchUpdate", body: { requests: requests })
        { document_id: answer["documentId"] || document_id, edits: requests.size, replies: Array(answer["replies"]).compact_blank.presence }.compact
      end

      def self.escape(id) = ERB::Util.url_encode(id)
    end

    # Google Chat, read only, as the signed-in person: their spaces and
    # direct messages, and the messages in one. Google has no search of
    # messages across spaces for a person (spaces.search finds spaces, and by
    # time only for an administrator), so there is none here.
    module Chat
      SPACE = %r{\Aspaces/[\w.-]+\z}
      MESSAGE = %r{\Aspaces/[\w.-]+/messages/[\w.-]+\z}
      THREAD = %r{\Aspaces/[\w.-]+/threads/[\w.-]+\z}
      TIME = /\A\d{4}-\d{2}-\d{2}T[\d:.]+(Z|[+-]\d{2}:\d{2})\z/
      TYPES = %w[ SPACE GROUP_CHAT DIRECT_MESSAGE ].freeze

      def self.list_spaces(token, type: nil, page_size:, page_token: nil)
        raise Error, "type must be one of #{TYPES.join(', ')}." if type.present? && !TYPES.include?(type)
        page = Google.request(token, :get, "#{CHAT}/spaces", query: { pageSize: page_size, pageToken: page_token, filter: (%(spaceType = "#{type}") if type.present?) })
        spaces = Array(page["spaces"]).map do
          { space: it["name"], name: it["displayName"].presence, type: it["spaceType"], last_active: it["lastActiveTime"], external: it["externalUserAllowed"] }.compact
        end
        { spaces: spaces, next_page_token: page["nextPageToken"] }.compact
      end

      # Newest first. after and before bound the time a message was sent.
      def self.list_messages(token, space:, after: nil, before: nil, thread: nil, page_size:, page_token: nil)
        check(space, SPACE, "space", "spaces/AAAA, from list_spaces")
        check(thread, THREAD, "thread", "spaces/AAAA/threads/BBBB, from a message") if thread.present?
        [ after, before ].compact_blank.each { raise Error, "#{it} isn't an RFC 3339 time, such as 2026-11-10T09:00:00Z." unless it.match?(TIME) }
        filter = [ (%(createTime > "#{after}") if after.present?), (%(createTime < "#{before}") if before.present?), (%(thread.name = #{thread}) if thread.present?) ].compact.join(" AND ")
        page = Google.request(token, :get, "#{CHAT}/#{space}/messages",
          query: { pageSize: page_size, pageToken: page_token, filter: filter.presence, orderBy: "createTime desc" })
        { messages: Array(page["messages"]).map { message(it) }, next_page_token: page["nextPageToken"] }.compact
      end

      def self.get_message(token, message:)
        check(message, MESSAGE, "message", "spaces/AAAA/messages/BBBB, from list_messages")
        message(Google.request(token, :get, "#{CHAT}/#{message}"))
      end

      # As the person; into the thread, or a new one if Google can't reply there.
      def self.send_message(token, space:, text:, thread: nil)
        check(space, SPACE, "space", "spaces/AAAA, from list_spaces")
        check(thread, THREAD, "thread", "spaces/AAAA/threads/BBBB, from a message") if thread.present?
        raise Error, "text is empty." if text.to_s.strip.empty?
        message(Google.request(token, :post, "#{CHAT}/#{space}/messages", query: (thread.present? ? { messageReplyOption: "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD" } : {}),
          body: { text: text, thread: ({ name: thread } if thread.present?) }.compact))
      end

      def self.react(token, message:, emoji:)
        check(message, MESSAGE, "message", "spaces/AAAA/messages/BBBB, from list_messages")
        raise Error, "emoji must be one unicode emoji, such as 👍." unless emoji.to_s.match?(/\A[\p{Extended_Pictographic}\p{Regional_Indicator}][\p{Extended_Pictographic}\p{Regional_Indicator}\p{Emoji_Modifier}\u200d\ufe0f\u20e3]*\z/)
        reaction = Google.request(token, :post, "#{CHAT}/#{message}/reactions", body: { emoji: { unicode: emoji } })
        { reaction: reaction["name"], message: message, emoji: reaction.dig("emoji", "unicode") }.compact
      end

      # The sender's name where Google gives it: to a person's sign-in, for
      # a member of the space or someone they have talked with. Otherwise
      # only their users/ id.
      def self.message(message)
        sender = message["sender"] || {}
        { message: message["name"], sender: sender["displayName"].presence || sender["name"], sender_id: sender["name"], sender_type: sender["type"],
          sent: message["createTime"], edited: message["lastUpdateTime"], thread: message.dig("thread", "name"),
          text: (message["text"].presence || message["formattedText"]).to_s.truncate(TEXT_LIMIT).presence,
          attachments: Array(message["attachment"]).map { it["contentName"] }.compact.presence }.compact
      end

      def self.check(value, pattern, name, example)
        raise Error, "#{name} must look like #{example}." unless value.to_s.match?(pattern)
      end
    end
  end
end
