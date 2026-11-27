module DurableAssistants
  class Caldav
    # What the calendar tools reach (Agent#caldav): the lists of the agent's
    # own account, if it has one, those of each account it only reads
    # (Caldav::ReadOnly), and each calendar linked from another account
    # (Caldav::Scoped), as one set of lists. Each call goes to the client whose
    # list it names; a linked calendar's name wins over an own list's.
    class Combined
      def initialize(own, linked, read_only = [])
        @own, @linked, @read_only = own, linked, read_only
      end

      # One server down leaves the others' lists, and #unreachable says why;
      # only when none answers does it fail, as a single server would.
      def lists
        @unreachable = []
        sources = [ @own, *@read_only, *@linked ].compact
        found = sources.flat_map { lists_of(it) }
        raise @unreachable.first if sources.any? && @unreachable.size == sources.size
        found
      end

      # What each server that could not be reached said, as the last #lists heard it.
      def unreachable = @unreachable.to_a.map(&:message).uniq

      def items(list, kind, **range) = client(list).items(list, kind, **range)
      def item(list, id) = client(list).item(list, id)
      def put(list, id, calendar, etag: nil) = client(list).put(list, id, calendar, etag: etag)
      def delete(list, id, etag) = client(list).delete(list, id, etag)

      # Whether a list is one only read, so a tool refuses to write there.
      def read_only?(list) = !linked(list) && @read_only.any? { it.list?(list) }

      private
        def lists_of(source)
          lists = source.lists
          source.equal?(@own) ? lists.reject { linked(it[:list]) } : lists
        rescue Error => error
          @unreachable << error
          []
        end

        def linked(list) = @linked.find { it.list == list }

        def client(list)
          linked(list) || @read_only.find { it.list?(list) } || @own or raise Error, "There is no list #{list}; calendar_lists names them."
        end
    end
  end
end
