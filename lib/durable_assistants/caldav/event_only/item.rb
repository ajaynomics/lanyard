module DurableAssistants
  class Caldav
    class EventOnly
      # Check the wire form as well as the parsed events: a parser can ignore a
      # component or property that the calendar server would act on.
      class Item
        CHILDREN = { "VCALENDAR" => %w[ VEVENT VTIMEZONE ], "VEVENT" => %w[ VALARM ],
          "VTIMEZONE" => %w[ STANDARD DAYLIGHT ] }.freeze
        ORDINARY = {
          "VCALENDAR" => %w[ VERSION PRODID CALSCALE ],
          "VEVENT" => %w[ UID DTSTAMP DTSTART DTEND DURATION SUMMARY DESCRIPTION LOCATION TRANSP STATUS CLASS
                         RRULE RDATE EXDATE RECURRENCE-ID CREATED LAST-MODIFIED SEQUENCE ],
          "VTIMEZONE" => %w[ TZID LAST-MODIFIED ],
          "STANDARD" => %w[ DTSTART TZOFFSETFROM TZOFFSETTO RRULE RDATE TZNAME ],
          "DAYLIGHT" => %w[ DTSTART TZOFFSETFROM TZOFFSETTO RRULE RDATE TZNAME ]
        }.freeze
        ORDINARY_PARAMS = /\A(?:;(?:VALUE|TZID|LANGUAGE|RANGE)=(?:"[^"]*"|[^;":]+))*:/i

        def initialize(body)
          @body = body.to_s.dup.force_encoding(Encoding::UTF_8)
          @ordinary = true
          check_shape!
        end

        def writable!
          refuse unless @ordinary
        end

        def calendar
          parsed = Icalendar::Calendar.parse(@body)
          refuse unless parsed.size == 1 && parsed.first.events.any?
          parsed.first.tap { |cal| cal.events.each { |event| event.alarms.clear } }
        rescue ArgumentError, TypeError
          refuse
        end

        private
          def check_shape!
            refuse unless @body.valid_encoding? && !@body.match?(/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]|\r(?!\n)/)
            stack = []
            seen_root = false
            events = 0
            @body.gsub(/\r?\n[ \t]/, "").split(/\r?\n/).each do |line|
              name = line[/\A([A-Za-z0-9-]+)[;:]/, 1]&.upcase
              refuse unless name
              case name
              when "BEGIN"
                kind = line[/\ABEGIN:([A-Za-z]+)\z/i, 1]&.upcase
                if stack.empty?
                  refuse if seen_root || kind != "VCALENDAR"
                  seen_root = true
                else
                  refuse unless CHILDREN.fetch(stack.last, []).include?(kind)
                end
                events += 1 if kind == "VEVENT"
                @ordinary = false if kind == "VALARM"
                stack << kind
              when "END"
                kind = line[/\AEND:([A-Za-z]+)\z/i, 1]&.upcase
                refuse unless kind && stack.pop == kind
              else
                refuse if stack.empty? || name == "METHOD"
                @ordinary &&= ORDINARY.fetch(stack.last, []).include?(name) && line[name.length..].match?(ORDINARY_PARAMS)
              end
            end
            refuse unless seen_root && stack.empty? && events.positive?
          end

          def refuse
            raise Error.new("This calendar allows only ordinary events without guests, alarms or scheduling to be changed.", status: 403)
          end
      end
    end
  end
end
