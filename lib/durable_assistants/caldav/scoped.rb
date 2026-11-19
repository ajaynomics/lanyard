module DurableAssistants
  class Caldav
    # One calendar in another account, such as a family's shared calendar on
    # iCloud (docs/calendar.md). That account's app password opens all of it:
    # every calendar, its contacts, its mail. So this client reaches only the
    # one calendar's collection and the items directly in it. The check is on
    # the address each request is about to go to, in #request, the one place
    # requests are made; the paths Caldav builds are not trusted to stay
    # inside. The person gives the collection's own address, so there is no
    # discovery: the account's principal and home are never asked.
    #
    # The username and app password are a vault entry, read as the agent for
    # each request and dropped after it: never kept, logged or shown. They go
    # only to the host saved with the entry, and an answer that echoes the
    # password has it replaced before anything reads the answer.
    class Scoped < Caldav
      ITEM = /\A[A-Za-z0-9][\w.@-]*\.ics\z/ # an item directly in the collection
      HIDDEN = "[the saved password]"

      def initialize(agent, collection:, entry:)
        @agent, @entry = agent, entry
        @base = URI(collection.to_s.delete_suffix("/") + "/")
      end

      # Its name for the calendar tools: the collection's last segment, as
      # Caldav names a list in an account's home.
      def list = @base.path.split("/").last

      def lists
        multistatus("PROPFIND", @base.path, LISTS, depth: 0)
          .select { name_in(it, under: home) == list }.filter_map { described(it, list) }.first(1)
      end

      def inspect = "#<#{self.class.name} #{@base}>"
      alias_method :to_s, :inspect

      private
        def home = @base.path.delete_suffix("#{list}/")

        # Built as asked and not checked here: #request decides.
        def path(list, id = nil) = "#{home}#{list}/#{"#{id}.ics" if id}"

        def request(kind, path, body = nil, headers = {})
          raise Error, "This agent may reach only #{reach} on #{@base.host}." unless inside?(URI.join(@base, path))
          entry = sign_in
          super(kind, path, body, headers, username: entry.username, password: entry.password).tap { hide(it, entry.password) }
        rescue URI::InvalidURIError
          raise Error, "#{path.inspect} is not an address on the calendar server."
        end

        def reach = "its #{list} calendar"

        # The collection itself, or one item directly in it, on its own server.
        def inside?(uri)
          return false unless [ uri.scheme, uri.host, uri.port ] == [ @base.scheme, @base.host, @base.port ]
          return false if uri.userinfo || uri.query || uri.fragment
          uri.path == @base.path || (uri.path.start_with?(@base.path) && uri.path.delete_prefix(@base.path).match?(ITEM))
        end

        def sign_in
          entry = Passbolt.sign_in(@agent, Passbolt.find_by_name(@agent, @entry).id)
          raise Error, "#{@entry} has no username and password saved." if entry.username.blank? || entry.password.blank?
          raise Error, "#{@entry} is saved for #{entry.host || "no address"}, not #{@base.host}, so it is not sent there." unless entry.host == @base.host.downcase
          entry
        rescue Passbolt::Error => error
          raise Error, error.message
        end

        def hide(response, password)
          return unless response.body
          response.body = response.body.dup.force_encoding(Encoding::UTF_8).scrub.gsub(password, HIDDEN)
        end
    end
  end
end
