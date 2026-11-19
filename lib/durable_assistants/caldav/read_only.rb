module DurableAssistants
  class Caldav
    # The lists of a CalDAV account the agent only reads (Agent::CalendarServer,
    # read_only), such as a colleague's whose work it took over. Each list is
    # named for its host, work@dav.example.com, so it never shadows one of the
    # agent's own, and its name says it is read only. Reading goes to the
    # account's client; saving or deleting is refused here, before anything
    # is sent, whatever a tool asked.
    class ReadOnly
      def initialize(client, host)
        @client, @suffix = client, "@#{host}"
      end

      # Another account's, whoever owns them there: never the agent's own, so
      # their alarms wake that account's owner and not this agent.
      def lists = @client.lists.map { it.merge(list: "#{it[:list]}#{@suffix}", name: "#{it[:name]} (read only)", own: false) }
      def list?(list) = list.to_s.end_with?(@suffix)
      def items(list, kind, **range) = @client.items(own(list), kind, **range)
      def item(list, id) = @client.item(own(list), id)
      def put(list, *, **) = refuse(list)
      def delete(list, *) = refuse(list)

      def inspect = "#<#{self.class.name} #{@client.inspect}>"
      alias_method :to_s, :inspect

      def self.refusal(list) = "#{list} is read only: nothing is saved or deleted there."

      private
        def own(list) = list.delete_suffix(@suffix)
        def refuse(list) = raise(Error, self.class.refusal(list))
    end
  end
end
