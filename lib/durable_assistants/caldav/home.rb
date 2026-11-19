module DurableAssistants
  class Caldav
    # The agent's own account on a CalDAV server of its own (Agent::CalendarServer),
    # in place of its account on the install's: every list in the account's
    # calendar home, as Caldav reads the install's. Its person gives the
    # home's address, so there is no discovery. Like Scoped, whose guard and
    # sign-in it keeps, every request is checked where it is about to go: the
    # home, one list directly in it, or one item directly in a list, on the
    # same server, with no query. The username and password are the vault
    # entry's, read for each request, sent only to the host saved with it and
    # hidden in any answer that echoes them.
    class Home < Scoped
      LIST = %r{\A[A-Za-z0-9][\w.@-]*/([A-Za-z0-9][\w.@-]*\.ics)?\z} # a list in the home, or an item in it

      def initialize(agent, home:, entry:)
        super(agent, collection: home, entry: entry)
      end

      def list = nil

      # Caldav's own: every list in the account's home, and which it owns.
      define_method(:lists, Caldav.instance_method(:lists))

      private
        def home = @base.path

        # Caldav's own: a list's and an item's name are each one path segment.
        define_method(:path, Caldav.instance_method(:path))

        def reach = "its own calendars"

        def inside?(uri)
          return false unless [ uri.scheme, uri.host, uri.port ] == [ @base.scheme, @base.host, @base.port ]
          return false if uri.userinfo || uri.query || uri.fragment
          uri.path == home || (uri.path.start_with?(home) && uri.path.delete_prefix(home).match?(LIST))
        end
    end
  end
end
