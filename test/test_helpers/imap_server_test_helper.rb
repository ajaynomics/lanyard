require "socket"
require "openssl"
require_relative "hung_imap_test_helper"

# A mail server on the loopback that speaks enough IMAP4rev1 for the real
# Net::IMAP client to sign in, list folders, open one, search it and fetch
# from it, over TLS checked as in production (HungImapTestHelper's
# certificate and name). It keeps every command it is sent and each
# message's flags, and marks a message \Seen when it is fetched without
# PEEK, as a real server does, so a test sees what reading changed. It
# stores flags (Gmail's labels among them), copies, moves and expunges by
# UID, and offers what `capabilities` says, so a test picks MOVE or Gmail's.
module ImapServerTestHelper
  # What only writes: never sent by what reads a mailbox.
  WRITES = %w[ SELECT STORE COPY MOVE EXPUNGE APPEND CREATE DELETE RENAME UID\ STORE UID\ COPY UID\ MOVE UID\ EXPUNGE ].freeze

  class ImapServer < HungImapTestHelper::HungImap
    Message = Struct.new(:uid, :raw, :date, :flags)
    attr_reader :commands, :folders
    attr_accessor :capabilities

    # folders: name => its special use (RFC 6154), such as :Sent, or nil.
    def initialize(name, folders)
      @uses, @folders, @commands, @uid, @capabilities = folders, folders.transform_values { [] }, [], 0, "IMAP4rev1"
      super(name, :serving)
    end

    def deliver(folder, raw, date: Time.current, flags: [])
      folders.fetch(folder) << Message.new(@uid += 1, raw.gsub(/\r?\n/, "\r\n"), date, flags)
    end

    # Gone from the box: neither listed nor openable.
    def forget(folder) = [ @uses, @folders ].each { it.delete(folder) }

    def flags = folders.transform_values { |messages| messages.to_h { [ it.uid, it.flags.dup ] } }
    def connections = commands.count { it.first == "LOGIN" }

    private
      def serve(socket)
        @clients << socket
        Thread.new do
          tls = OpenSSL::SSL::SSLSocket.new(socket, @context).tap(&:accept)
          tls.write "* OK [CAPABILITY #{capabilities}] ready\r\n"
          while (line = tls.gets("\r\n"))
            tag, *words = words(tls, line)
            command = words.shift.upcase
            command = "UID #{words.shift.upcase}" if command == "UID"
            commands << [ command, *words ]
            tls.write "#{tag} #{answer(tls, command, words)}\r\n"
          end
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        end
      end

      # One command's words, quoted strings and literals unwrapped, parentheses dropped.
      def words(tls, line)
        literals = []
        while (size = line[/\{(\d+)\}\r\n\z/, 1])
          tls.write "+ go\r\n"
          literals << tls.read(size.to_i)
          line = line.sub(/\{\d+\}\r\n\z/, "\x00#{literals.size - 1}") + tls.gets("\r\n")
        end
        line.scan(/"((?:[^"\\]|\\.)*)"|\x00(\d+)|([^\s()"]+)/).map { |quoted, literal, atom| quoted&.gsub(/\\(.)/, '\1') || (literal ? literals[literal.to_i] : atom) }
      end

      def answer(tls, command, words)
        case command
        when "CAPABILITY" then tls.write "* CAPABILITY #{capabilities}\r\n"
        when "LOGIN", "LOGOUT", "NOOP" then nil
        when "LIST" then @uses.each { |name, use| tls.write %(* LIST (\\HasNoChildren#{" \\#{use}" if use}) "/" "#{name}"\r\n) }
        when "EXAMINE", "SELECT"
          @open = folders[words.first] or return "NO no such folder"
          tls.write "* #{@open.size} EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n"
          return "OK [#{command == "EXAMINE" ? "READ-ONLY" : "READ-WRITE"}] done"
        when "UID SEARCH" then tls.write [ "* SEARCH", *@open.select { |message| search(message, words.dup) }.map(&:uid) ].join(" ") + "\r\n"
        when "UID FETCH" then fetch(tls, words)
        when "UID STORE"
          sign, values = words[1][0], words[2..]
          chosen(words[0]).each { |message| message.flags = sign == "+" ? message.flags | values : message.flags - values }
        when "UID COPY", "UID MOVE"
          into = folders[words[1]] or return "NO no such folder"
          chosen(words[0]).each { |message| into << message.dup.tap { it.uid, it.flags = @uid += 1, it.flags.dup } }
          @open.replace(@open - chosen(words[0])) if command == "UID MOVE"
        when "UID EXPUNGE" then @open.replace(@open - chosen(words[0]).select { it.flags.include?("\\Deleted") })
        else return "NO not on this server"
        end
        "OK done"
      end

      def search(message, keys)
        found = true
        found = key?(message, keys) && found while keys.any?
        found
      end

      def key?(message, keys)
        case key = keys.shift.upcase
        when "ALL" then true
        when "CHARSET" then keys.shift && true
        when "FROM", "TO", "SUBJECT" then header(message, key).include?(keys.shift.downcase)
        when "HEADER" then header(message, keys.shift).include?(keys.shift.downcase)
        when "SINCE" then message.date.utc.to_date >= Date.parse(keys.shift)
        when "BEFORE" then message.date.utc.to_date < Date.parse(keys.shift)
        when "OR" then [ key?(message, keys), key?(message, keys) ].any?
        else raise ArgumentError, "SEARCH #{key} is not spoken here"
        end
      end

      # A header's raw value, unfolded and in lower case, as servers match it.
      def header(message, name)
        head = message.raw.split("\r\n\r\n", 2).first
        head.scan(/^#{Regexp.escape(name)}:(.*(?:\r\n[ \t].*)*)/i).join(" ").gsub(/\r\n/, "").downcase
      end

      # The open folder's messages with these UIDs, as 1,3:5.
      def chosen(set)
        ranges = set.split(",").map { |range| range.split(":").map(&:to_i).then { (it.first..it.last) } }
        @open.select { |message| ranges.any? { it.cover?(message.uid) } }
      end

      def fetch(tls, words)
        uids = chosen(words.shift).map(&:uid)
        @open.each.with_index(1) do |message, number|
          tls.write "* #{number} FETCH (#{words.map { item(message, it) }.join(" ")})\r\n" if uids.include?(message.uid)
        end
      end

      def item(message, name)
        case name.upcase
        when "UID" then "UID #{message.uid}"
        when "FLAGS" then "FLAGS (#{message.flags.join(" ")})"
        when "INTERNALDATE" then %(INTERNALDATE "#{message.date.utc.strftime("%d-%b-%Y %H:%M:%S +0000")}")
        when "RFC822.SIZE" then "RFC822.SIZE #{message.raw.bytesize}"
        when /\ABODY(\.PEEK)?\[(HEADER)?\](?:<(\d+)\.(\d+)>)?\z/
          peek, part, start, length = $~.captures
          message.flags |= [ "\\Seen" ] unless peek
          text = part ? message.raw.split("\r\n\r\n", 2).first + "\r\n\r\n" : message.raw
          text = text.byteslice(start.to_i, length.to_i) if start
          "BODY[#{part}]#{"<#{start}>" if start} {#{text.bytesize}}\r\n#{text}"
        else raise ArgumentError, "FETCH #{name} is not spoken here"
        end
      end
  end

  # Serves `folders` for `name` on the loopback until #stop_imap: Net::IMAP
  # itself connects to it, trusting its certificate alone.
  def start_imap(name, folders)
    @imap = ImapServer.new(name, folders)
    @imap_ssl, DurableAssistants::Email.ssl = DurableAssistants::Email.ssl, { cert_store: @imap.trust }
    tcp = @imap_tcp = Socket.method(:tcp)
    Socket.define_singleton_method(:tcp) { |host, port, *rest, **options| tcp.call(host == name ? "127.0.0.1" : host, port, *rest, **options) }
    @imap
  end

  def stop_imap
    Socket.define_singleton_method(:tcp, @imap_tcp) if @imap_tcp
    DurableAssistants::Email.ssl = @imap_ssl if @imap
    @imap&.stop
  end
end
