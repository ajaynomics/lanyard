module DurableAssistants
  class Caldav
    # What the calendar tools reach (Agent#caldav): the lists of the agent's
    # own account, if it has one, those of each account it only reads
    # (Caldav::ReadOnly), and its one linked calendar, if it has one
    # (Caldav::Scoped), as one set of lists. Each call goes to the client whose
    # list it names; the linked calendar's name wins over an own list's.
    class Combined
      def initialize(own, linked, read_only = [])
        @own, @linked, @read_only = own, linked, read_only
      end

      def lists = [ *own_lists, *@read_only.flat_map(&:lists), *@linked&.lists ]
      def items(list, kind, **range) = client(list).items(list, kind, **range)
      def item(list, id) = client(list).item(list, id)
      def put(list, id, calendar, etag: nil) = client(list).put(list, id, calendar, etag: etag)
      def delete(list, id, etag) = client(list).delete(list, id, etag)

      # Whether a list is one only read, so a tool refuses to write there.
      def read_only?(list) = !(@linked && list == @linked.list) && @read_only.any? { it.list?(list) }

      private
        def own_lists = @own ? @own.lists.reject { it[:list] == @linked&.list } : []

        def client(list)
          return @linked if @linked && list == @linked.list
          @read_only.find { it.list?(list) } || @own or raise Error, "There is no list #{list}; calendar_lists names them."
        end
    end
  end
end
