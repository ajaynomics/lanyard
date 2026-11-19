# A CalDAV server in memory, as Radicale answers (docs/calendar.md): one
# account's home with a calendar and a task list, items kept by name with an
# ETag, PUT and DELETE honouring If-Match and If-None-Match. A REPORT answers
# every item of the list; the time-range and the expansion of a repeating
# event are the server's, and are left to the real one. Each collection names
# its owner, as a server does, so a list shared into the home can be told from
# the account's own (share_caldav_list).
module CaldavTestHelper
  URL = "https://caldav.example.com"
  LISTS = { "calendar" => [ "Maya's calendar", "VEVENT" ], "tasks" => [ "Maya's tasks", "VTODO" ] }.freeze

  def install_caldav(username: "agent-1", password: "app-password")
    @caldav_previous = Rails.application.config.x.caldav[:url]
    Rails.application.config.x.caldav[:url] = URL
    @caldav_items = Hash.new { |items, list| items[list] = {} }
    @caldav_account = [ username, password ]
    @caldav_shared = {}
    stub_request(:any, /\A#{Regexp.escape(URL)}/).to_return { caldav_answer(it) }
    @caldav_items
  end

  # A list another account owns, shared into this one's home: it answers under
  # the home like the account's own, with that account's owner and the address
  # it was shared from, as CalendarServer and SabreDAV give them.
  def share_caldav_list(name, title: "Robin's tasks", component: "VTODO", owner: "/robin/")
    @caldav_shared[name] = [ title, component, owner ]
  end

  def remove_caldav = Rails.application.config.x.caldav[:url] = @caldav_previous

  def caldav_item(list, id) = Icalendar::Calendar.parse(@caldav_items[list].fetch(id).last).first

  def caldav_put(list, id, ics) = @caldav_items[list][id] = [ %("#{SecureRandom.hex(8)}"), ics ]

  private
    def caldav_answer(request)
      username, password = @caldav_account
      return { status: 401 } unless request.headers["Authorization"] == "Basic #{Base64.strict_encode64("#{username}:#{password}")}"
      home = "/#{username}/"
      path = URI(request.uri.to_s).path
      list, file = path.delete_prefix(home).split("/", 2)
      id = file&.delete_suffix(".ics")
      case request.method
      when :propfind then multistatus(home_and_lists(home))
      when :report then multistatus(@caldav_items[list].map { |key, (etag, ics)| item(home + list + "/" + key + ".ics", etag, ics) })
      when :get then @caldav_items[list].key?(id) ? { status: 200, body: @caldav_items[list][id].last, headers: { "ETag" => @caldav_items[list][id].first } } : { status: 404 }
      when :put then put(list, id, request)
      when :delete
        return { status: 412 } unless @caldav_items[list][id]&.first == request.headers["If-Match"]
        @caldav_items[list].delete(id) and { status: 200 }
      end
    end

    def put(list, id, request)
      stored = @caldav_items[list][id]
      return { status: 412 } if request.headers["If-None-Match"] == "*" && stored
      return { status: 412 } if request.headers["If-Match"] && stored&.first != request.headers["If-Match"]
      Icalendar::Calendar.parse(request.body).first or return { status: 400 }
      return { status: 400 } if request.body.match?(/^TRIGGER[^:]*:-?P\r?$/) # Radicale refuses a duration of "P"
      caldav_put(list, id, request.body)
      { status: 201 }
    end

    # Depth 1 on a home answers for the home itself as well as its lists.
    def home_and_lists(home)
      own = LISTS.map { |name, (title, component)| collection(home + name + "/", title, component, owner: home) }
      shared = @caldav_shared.map { |name, (title, component, owner)| collection(home + name + "/", title, component, owner: owner, shared_from: owner + name + "/") }
      [ collection(home, "Home", nil, owner: home), *own, *shared ]
    end

    def multistatus(responses)
      { status: 207, headers: { "Content-Type" => "application/xml" }, body: <<~XML }
        <?xml version="1.0"?>
        <multistatus xmlns="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav" xmlns:CS="http://calendarserver.org/ns/">#{responses.join}</multistatus>
      XML
    end

    # A calendar or task list, or the home itself (no component). `owner` is
    # the principal the server says owns it; `shared_from` is the address it
    # was shared from, which only a sharee's copy carries.
    def collection(href, title, component, owner: nil, shared_from: nil)
      <<~XML
        <response><href>#{href}</href><propstat><prop><displayname>#{title}</displayname>
        <resourcetype><collection/>#{"<C:calendar/>" if component}</resourcetype>
        #{"<C:supported-calendar-component-set><C:comp name=\"#{component}\"/></C:supported-calendar-component-set>" if component}
        #{"<owner><href>#{owner}</href></owner>" if owner}
        #{"<CS:shared-url><href>#{shared_from}</href></CS:shared-url>" if shared_from}
        </prop><status>HTTP/1.1 200 OK</status></propstat></response>
      XML
    end

    def item(href, etag, ics)
      <<~XML
        <response><href>#{href}</href><propstat><prop><getetag>#{etag.encode(xml: :text)}</getetag>
        <C:calendar-data>#{ics.encode(xml: :text)}</C:calendar-data></prop><status>HTTP/1.1 200 OK</status></propstat></response>
      XML
    end
end
