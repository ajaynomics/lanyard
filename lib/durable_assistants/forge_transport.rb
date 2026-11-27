require "json"
require "socket"
require "timeout"

module DurableAssistants
  # A local, permissions-gated socket is the destination. No reconnect.
  module ForgeTransport
    LINE_LIMIT = 16 * 1024

    class UniqueObject < Hash
      def []=(key, value)
        raise IOError if key?(key)
        super
      end
    end

    def self.call(socket_path, context:, operation:, timeout:, reply_frame_limit: nil)
      request = JSON.generate(context: context, operation: operation) + "\n"
      raise IOError unless request.bytesize <= LINE_LIMIT

      Timeout.timeout(timeout) do
        check_path(socket_path)
        UNIXSocket.open(socket_path) do |socket|
          peer = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_PEERCRED)
          raise IOError unless peer.data.unpack("i!I!I!")[1] == 0

          socket.write(request)
          reply = read_line(socket)
          frame = read_frame(socket, reply, reply_frame_limit) if reply_frame_limit && reply["status"] == "ok"
          raise IOError if socket.read(1)
          [ reply, frame ]
        end
      end
    end

    def self.check_path(path)
      raise IOError unless path.start_with?("/")
      stat = File.lstat(path)
      raise IOError unless stat.socket? && stat.uid.zero? && [ 0o600, 0o660 ].include?(stat.mode & 0o7777)
      # A trusted leaf does not protect the pathname if an ancestor can be replaced.
      until path == "/"
        path = File.dirname(path)
        directory = File.lstat(path)
        raise IOError unless directory.directory? && directory.uid.zero? && (directory.mode & 0o022).zero?
      end
    end

    def self.read_line(socket)
      line = socket.gets("\n", LINE_LIMIT + 1)&.force_encoding(Encoding::UTF_8)
      raise IOError unless line&.valid_encoding? && line.bytesize <= LINE_LIMIT && line.end_with?("\n")
      parsed = JSON.parse(line, object_class: UniqueObject)
      raise IOError unless parsed.is_a?(Hash)
      parsed
    rescue JSON::ParserError
      raise IOError, cause: nil
    end

    def self.read_frame(socket, reply, limit)
      header = socket.read(8)
      raise IOError unless header&.bytesize == 8
      length = header.unpack1("Q>")
      raise IOError unless length <= limit && reply["bytes"].is_a?(Integer) && length == reply["bytes"]
      bytes = socket.read(length)
      raise IOError unless bytes&.bytesize == length
      bytes
    end

    private_class_method :check_path, :read_line, :read_frame
  end
end
