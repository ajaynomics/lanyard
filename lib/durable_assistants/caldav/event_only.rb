module DurableAssistants
  class Caldav
    class EventOnly < Scoped
      PATH = %r{\A/(?:[A-Za-z0-9][A-Za-z0-9_.@-]*/)+\z}
      ETAG = /\A"[\x21\x23-\x7e]*"\z/

      def self.collection_uri(value)
        uri = URI(value.to_s)
        return unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.host == uri.host.downcase
        return if uri.userinfo || uri.query || uri.fragment || uri.to_s != value.to_s || !uri.path.match?(PATH)
        uri
      rescue URI::Error
        nil
      end

      def initialize(agent, collection:, entry:)
        uri = self.class.collection_uri(collection)
        raise Error, "Name the full HTTPS address of one calendar collection." unless uri
        super(agent, collection: uri, entry:)
      end

      def lists = [ { list:, name: list, kinds: [ "events" ], own: false } ]

      def items(list, kind, from: nil, to: nil)
        refused unless kind == "events"
        response = request(Report, path(list), calendar_query(kind, from, to), { "Depth" => "1", "Content-Type" => "application/xml; charset=utf-8" })
        ensure!(response, "read the calendar")
        xml = Nokogiri::XML(response.body) { |options| options.strict.nonet }
        xml.xpath("/d:multistatus/d:response", "d" => "DAV:").filter_map { |entry| listed_item(entry) }
      rescue Nokogiri::XML::SyntaxError
        refused
      end

      def item(list, id)
        read_item(list, id)
      end

      def put(list, id, calendar, etag: nil)
        body = calendar.to_ical
        Item.new(body).writable!
        check_version!(list, id, etag) unless etag.nil?
        headers = { "Content-Type" => "text/calendar; charset=utf-8", (etag ? "If-Match" : "If-None-Match") => etag || "*" }
        ensure!(request(Net::HTTP::Put, path(list, id), body, headers), "save #{id}")
      end

      def delete(list, id, etag)
        check_version!(list, id, etag)
        super
      end

      private
        def listed_item(entry)
          namespaces = { "d" => "DAV:", "c" => "urn:ietf:params:xml:ns:caldav" }
          hrefs = entry.xpath("d:href", namespaces)
          return unless hrefs.one?
          id = item_in(hrefs.first.text)
          return unless id
          props = entry.xpath("d:propstat", namespaces).select do |stat|
            stat.at_xpath("d:status", namespaces)&.text.to_s.match?(%r{\AHTTP/\d(?:\.\d)? 200(?: |\z)})
          end
          data = props.flat_map { |stat| stat.xpath("d:prop/c:calendar-data", namespaces) }
          [ id, "", Item.new(data.first.text).calendar ] if data.one?
        rescue Error
          nil
        end

        def item_in(href)
          uri = URI(href)
          return if uri.userinfo || uri.query || uri.fragment
          return if (uri.host || uri.scheme) && [ uri.scheme, uri.host, uri.port ] != [ @base.scheme, @base.host, @base.port ]
          return unless uri.path&.start_with?(@base.path)
          name = uri.path.delete_prefix(@base.path)
          name.delete_suffix(".ics") if name.match?(ITEM)
        rescue URI::Error
          nil
        end

        def check_version!(list, id, expected)
          stale unless expected.is_a?(String) && expected.match?(ETAG)
          read_item(list, id) do |item, current|
            stale unless current == expected
            item.writable!
          end
        rescue Error => problem
          stale if problem.status == 404
          raise
        end

        def read_item(list, id)
          validator = ""
          response = request(Net::HTTP::Get, path(list, id)) do |wire, password|
            ensure!(wire, "read #{id}")
            tags = wire.get_fields("etag")
            validator = tags.first if tags&.one? && tags.first.match?(ETAG) && !tags.first.include?(password)
            item = Item.new(wire.body)
            yield item, validator if block_given?
          end
          [ validator, Item.new(response.body).calendar ]
        end

        def path(name, id = nil)
          refused unless name == list && (id.nil? || id.is_a?(String) && id.match?(SEGMENT))
          "#{@base.path}#{"#{id}.ics" if id}"
        end

        def request(kind, target, body = nil, headers = {})
          if target == @base.path
            refused unless kind == Report && headers["Depth"] == "1"
          else
            refused unless target.start_with?(@base.path) && target.delete_prefix(@base.path).match?(ITEM)
            refused unless [ Net::HTTP::Get, Net::HTTP::Put, Net::HTTP::Delete ].include?(kind)
          end
          super
        end

        def retry_requests? = false

        def stale
          raise Error.new("The calendar server did not confirm that version. Read it again, then retry.", status: 412)
        end

        def refused
          raise Error.new("This agent may reach only events in the calendar its owner selected.", status: 403)
        end
    end
  end
end
