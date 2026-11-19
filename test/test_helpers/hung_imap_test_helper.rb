require "socket"
require "openssl"

# A mail server that takes the connection and then hangs, on the loopback,
# for what a send waits on over IMAP (DurableAssistants::Email.connect). It
# goes silent at one of three points: before TLS, after TLS but before its
# greeting, or after greeting, reading each command and answering none.
# Its certificate is for the account's own incoming server's name, from an
# authority only the test trusts, so TLS is checked as in production; only
# that name's address is the loopback's. The time limits are cut to a
# second each so the tests stay fast.
module HungImapTestHelper
  STOPS = %i[ before_tls before_greeting after_greeting ].freeze
  # Far past a second's limit, well short of a run that hangs for good.
  PATIENCE = 8

  # Not a StandardError, so nothing in the app can take it for the server's.
  class StillWaiting < Exception; end

  class HungImap
    attr_reader :port, :trust

    def initialize(name, stop)
      @stop, @clients = stop, Queue.new
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new.tap do |cert|
        cert.version, cert.serial, cert.public_key = 2, 1, key.public_key
        cert.subject = cert.issuer = OpenSSL::X509::Name.parse("/CN=#{name}")
        cert.not_before, cert.not_after = 1.hour.ago, 1.hour.from_now
        cert.add_extension(OpenSSL::X509::ExtensionFactory.new(cert, cert).create_extension("subjectAltName", "DNS:#{name}"))
        cert.sign(key, OpenSSL::Digest.new("SHA256"))
      end
      @trust = OpenSSL::X509::Store.new.tap { it.add_cert(certificate) }
      @context = OpenSSL::SSL::SSLContext.new.tap { it.cert, it.key = certificate, key }
      @tcp = TCPServer.new("127.0.0.1", 0)
      @port = @tcp.addr[1]
      @thread = Thread.new { loop { serve(@tcp.accept) } }
    end

    def stop
      @thread.kill
      @tcp.close
      @clients.close
      while (client = @clients.pop) do client.close end
    end

    private
      def serve(socket)
        @clients << socket
        Thread.new do
          next if @stop == :before_tls
          tls = OpenSSL::SSL::SSLSocket.new(socket, @context).tap(&:accept)
          next if @stop == :before_greeting
          tls.write "* OK ready\r\n"
          nil while tls.gets
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
          nil
        end
      end
  end

  # Runs the block against a hung server answering for `name` on `port`,
  # with Net::IMAP's own `new` restored, and returns what it returned and
  # how many seconds it took; fails once PATIENCE runs out rather than hang.
  def against_hung_imap(name, stop, original_new:)
    server = HungImap.new(name, stop)
    Net::IMAP.define_singleton_method(:new, original_new)
    saved_ssl, DurableAssistants::Email.ssl = DurableAssistants::Email.ssl, { cert_store: server.trust }
    tcp = Socket.method(:tcp)
    Socket.define_singleton_method(:tcp) { |host, port, *rest, **options| tcp.call(host == name ? "127.0.0.1" : host, port, *rest, **options) }
    stub_const(DurableAssistants::Email, :OPEN_TIMEOUT, 1) do
      stub_const(DurableAssistants::Email, :READ_TIMEOUT, 1) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        value = Timeout.timeout(PATIENCE, StillWaiting) { yield server }
        [ value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started ]
      end
    end
  rescue StillWaiting
    flunk "still waiting on a mail server that never answers (#{stop}) after #{PATIENCE} seconds"
  ensure
    Socket.define_singleton_method(:tcp, tcp) if tcp
    DurableAssistants::Email.ssl = saved_ssl if server
    server&.stop
  end
end
