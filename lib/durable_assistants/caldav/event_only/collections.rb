module DurableAssistants
  class Caldav
    class EventOnly
      class Collections
        def initialize(agent, urls:, entry:)
          @clients = urls.map { |collection| EventOnly.new(agent, collection:, entry:) }.index_by(&:list)
        end

        def lists = @clients.values.flat_map(&:lists)
        def items(list, ...) = pinned(list).items(list, ...)
        def item(list, ...) = pinned(list).item(list, ...)
        def put(list, ...) = pinned(list).put(list, ...)
        def delete(list, ...) = pinned(list).delete(list, ...)

        private
          def pinned(list)
            @clients.fetch(list) { raise Error.new("That calendar is not in the owner's list.", status: 403) }
          end
      end
    end
  end
end
