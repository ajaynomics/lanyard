module ForgeSocketTestHelper
  Stat = Struct.new(:uid, :mode, :socket?, :directory?, :gid)
  SocketStub = Struct.new(:peer_uid, :writes, :reply, :frame, :length) do
    def getsockopt(*) = Struct.new(:data).new([ 1, peer_uid, 0 ].pack("i!I!I!"))
    def write(line) = writes << line

    def gets(*arguments)
      response = reply.call(JSON.parse(writes.first))
      line = response.is_a?(Hash) ? response.to_json + "\n" : response
      binary = frame && [ length || frame.bytesize ].pack("Q>") + frame.b
      @wire = StringIO.new(line.b + binary.to_s)
      @wire.gets(*arguments)
    end

    def read(length) = @wire.read(length)
  end

  def with_fake_forge_socket(path, uid: 0, mode: 0o660, socket: true, peer_uid: 0, dir_uid: 0, dir_mode: 0o755,
    reply: ->(_) { { number: 8 } }, frame: nil, length: nil)
    stat = Stat.new(uid, mode, socket)
    directory = Stat.new(dir_uid, dir_mode, false, true, 0)
    connection = SocketStub.new(peer_uid, [], reply, frame, length)
    original_stat = File.method(:lstat)
    original_open = UNIXSocket.method(:open)
    File.define_singleton_method(:lstat) do |name|
      if name == path then stat
      elsif name == File.dirname(path) then directory
      else original_stat.call(name)
      end
    end
    UNIXSocket.define_singleton_method(:open) { |_path, &block| block.call(connection) }
    yield connection
  ensure
    File.define_singleton_method(:lstat, original_stat)
    UNIXSocket.define_singleton_method(:open, original_open)
  end
end
