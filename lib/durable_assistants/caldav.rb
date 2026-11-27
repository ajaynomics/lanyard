require "net/http"

module DurableAssistants
  # An agent's calendars and task lists on the install's CalDAV server, as the
  # agent's own account (docs/calendar.md). Rails keeps no copy: a read asks
  # the server, and a write is one PUT or DELETE naming the version it read
  # (If-Match), so nothing changed meanwhile on a phone is overwritten. Only
  # the account's own home is asked for; a list shared with the account shows
  # there too. Repeating events come back as their occurrences, expanded by
  # the server.
  class Caldav
    TIMEOUT = 15 # seconds
    SEGMENT = /\A[A-Za-z0-9][\w.@-]*\z/ # a list's or an item's name in a path
    KINDS = { "events" => "VEVENT", "tasks" => "VTODO" }.freeze

    # Its message is written for the agent: what failed and why, never what
    # an item holds. The status is the server's answer, if it gave one.
    class Error < StandardError
      attr_reader :status

      def initialize(message = nil, status: nil, unanswered: false)
        super(message)
        @status, @unanswered = status, unanswered
      end

      # Whether a write may have landed despite it: the server failed on its
      # own side (5xx), or took the request and never answered. A refusal
      # (4xx), or a connection never made, wrote nothing.
      def uncertain? = @unanswered || status.to_i >= 500
    end

    # Failures before a byte of the request is sent.
    UNSENT = [ Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, Net::OpenTimeout ].freeze

    # CalDAV's query (RFC 4791), which Net::HTTP does not name.
    class Report < Net::HTTPRequest
      METHOD = "REPORT"
      REQUEST_HAS_BODY = RESPONSE_HAS_BODY = true
    end

    def self.url = DurableAssistants.config(:caldav, :url).presence
    def self.configured? = url.present?

    def initialize(username, password)
      @username, @password = username, password
      @base = URI(self.class.url.to_s.delete_suffix("/") + "/")
    end

    # Every list in the account's home that holds events or tasks, each saying
    # whether the account owns it or it is only shared with it:
    # [{ list: "calendar", name: "Robin", kinds: ["events"], own: true }].
    def lists
      described_in(multistatus("PROPFIND", home, LISTS, depth: 1), under: home)
    end

    # The list's items of one kind, [[id, etag, calendar]]; with a range, only
    # those in it, and a repeating event as each of its occurrences there.
    def items(list, kind, from: nil, to: nil)
      multistatus("REPORT", path(list), calendar_query(kind, from, to), depth: 1).filter_map do |response|
        id, data = name_in(response, under: path(list))&.delete_suffix(".ics"), response.at_xpath(".//calendar-data")&.text
        [ id, etag(response.at_xpath(".//getetag")&.text), Icalendar::Calendar.parse(data).first ] if id && data.present?
      end
    end

    # One item as stored, with its version: [etag, calendar].
    def item(list, id)
      response = request(Net::HTTP::Get, path(list, id))
      raise Error.new("No item #{id} in #{list}.", status: 404) if response.is_a?(Net::HTTPNotFound)
      ensure!(response, "read #{id}")
      [ etag(response["etag"]), Icalendar::Calendar.parse(response.body.force_encoding(Encoding::UTF_8)).first ]
    end

    # A new item (no etag), or a new version of the one read at `etag`.
    def put(list, id, calendar, etag: nil)
      headers = { "Content-Type" => "text/calendar; charset=utf-8", (etag ? "If-Match" : "If-None-Match") => etag || "*" }
      ensure!(request(Net::HTTP::Put, path(list, id), calendar.to_ical, headers), "save #{id}")
    end

    def delete(list, id, etag)
      ensure!(request(Net::HTTP::Delete, path(list, id), nil, { "If-Match" => etag }), "delete #{id}")
    end

    private
      def calendar_query(kind, from, to)
        component = KINDS.fetch(kind)
        range = %(<C:time-range start="#{stamp(from)}" end="#{stamp(to)}"/>) if from && to
        data = from && to && kind == "events" ? %(<C:calendar-data><C:expand start="#{stamp(from)}" end="#{stamp(to)}"/></C:calendar-data>) : "<C:calendar-data/>"
        <<~XML
          <?xml version="1.0" encoding="utf-8"?>
          <C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">
            <D:prop><D:getetag/>#{data}</D:prop>
            <C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="#{component}">#{range}</C:comp-filter></C:comp-filter></C:filter>
          </C:calendar-query>
        XML
      end

      LISTS = <<~XML.freeze
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/">
          <D:prop><D:displayname/><D:resourcetype/><D:owner/><CS:shared-url/><C:supported-calendar-component-set/></D:prop>
        </D:propfind>
      XML

      def home = "/#{@username}/"

      def path(list, id = nil)
        raise Error, "#{list.inspect} is not a list's name." unless list.to_s.match?(SEGMENT)
        raise Error, "#{id.inspect} is not an item's id." unless id.nil? || id.to_s.match?(SEGMENT)
        "#{home}#{list}/#{"#{id}.ics" if id}"
      end

      # Depth 1 on a home describes the home itself as well as its lists, so
      # the owner the server gives the home is the account's own principal.
      # A list with another owner, or carrying the address it was shared
      # from, belongs to someone else and is only shared into the home.
      def described_in(responses, under:)
        principal = owner_of(responses.find { href_in(it) == under })
        responses.filter_map { described(it, name_in(it, under: under), own: owns?(it, principal)) }
      end

      # In doubt, a list is shared: a server that names no owner, or names
      # one for the list and not the home, owns nothing here as far as this
      # is concerned (docs/calendar.md, "Alarms on its own lists").
      def owns?(response, principal)
        principal.present? && owner_of(response) == principal && response.at_xpath(".//shared-url/href").nil?
      end

      # The principal a response says owns it. A property the server does not
      # keep comes back empty, in its own 404 propstat, and counts as none.
      def owner_of(response) = response && path_of(response.at_xpath(".//owner/href")&.text).presence

      # The one path segment a response names below `under`, or nil.
      def name_in(response, under:)
        href = href_in(response)
        name = href.delete_prefix(under).delete_suffix("/") if href&.start_with?(under) && href != under
        name if name&.match?(SEGMENT)
      end

      def href_in(response) = path_of(response.at_xpath("./href")&.text)

      # A DAV href as a path: a server may give a full address, and escape it.
      def path_of(href)
        URI::DEFAULT_PARSER.unescape(URI(href.to_s.strip).path.to_s)
      rescue URI::InvalidURIError
        nil
      end

      # A collection the PROPFIND described, as the tools name it, if it holds events or tasks.
      def described(response, list, own: false)
        kinds = KINDS.select { |_, component| response.at_xpath(".//comp[@name='#{component}']") }.keys
        { list: list, name: response.at_xpath(".//displayname")&.text.presence || list, kinds: kinds, own: own } if list && kinds.any?
      end

      def stamp(time) = time.utc.strftime("%Y%m%dT%H%M%SZ")

      # Behind Cloudflare a strong ETag can come back weak; If-Match needs it strong.
      def etag(value) = value.to_s.strip.delete_prefix("W/").presence

      def multistatus(verb, path, body, depth:)
        response = request(verb == "REPORT" ? Report : Net::HTTP::Propfind, path, body, { "Depth" => depth.to_s, "Content-Type" => "application/xml; charset=utf-8" })
        ensure!(response, verb == "PROPFIND" ? "list the calendars" : "read the list")
        Nokogiri::XML(response.body).tap(&:remove_namespaces!).xpath("/multistatus/response")
      end

      def ensure!(response, what)
        return response if response.is_a?(Net::HTTPSuccess)
        said = case response
        when Net::HTTPUnauthorized then "The calendar server refused this agent's username and password."
        when Net::HTTPPreconditionFailed then "It changed since you read it. Find it again, then retry."
        when Net::HTTPForbidden, Net::HTTPNotFound then "The calendar server has no such list for this agent, or it isn't shared with it to change."
        else "The calendar server couldn't #{what} (HTTP #{response.code})."
        end
        raise Error.new(said, status: response.code.to_i)
      end

      # The one place a request is made, so Caldav::Scoped guards it here.
      def request(kind, path, body = nil, headers = {}, username: @username, password: @password)
        uri = URI.join(@base, path)
        message = kind.new(uri, headers)
        message.basic_auth(username, password)
        message.body = body if body
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
          http.max_retries = 0 unless retry_requests?
          http.request(message)
        end
      rescue IOError, SystemCallError, Timeout::Error, SocketError, OpenSSL::SSL::SSLError => problem
        raise Error.new("Could not reach the calendar server (#{problem.class.name.demodulize}).", unanswered: UNSENT.none? { problem.is_a?(it) })
      end

      def retry_requests? = true
  end
end
