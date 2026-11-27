class ForgeFiles::Session
  MODES = %w[ stage push ].freeze
  ID = /\A[0-9a-f]{32}\z/
  SHA = /\A[0-9a-f]{64}\z/

  attr_reader :id, :mode, :bytes, :sha256

  def self.start(invocation, mode, bytes, sha256)
    validate!(bytes, sha256)
    session = new(invocation, SecureRandom.hex(16), mode.to_s, bytes, sha256)
    session.create { yield session }
  end

  def self.find(invocation, id, mode)
    raise ForgeFiles::Invalid unless id.is_a?(String) && ID.match?(id)
    session = new(invocation, id, mode)
    session.load
    session
  rescue Errno::ENOENT
    raise ActiveRecord::RecordNotFound
  end

  def self.validate!(bytes, sha256)
    raise ForgeFiles::TooLarge if bytes.is_a?(Integer) && bytes > ForgeFiles::MAX_BYTES
    raise ForgeFiles::Invalid unless bytes.is_a?(Integer) && bytes.positive? && sha256.is_a?(String) && SHA.match?(sha256)
  end

  def initialize(invocation, id, mode, bytes = nil, sha256 = nil)
    @id, @mode, @bytes, @sha256 = id, mode, bytes, sha256
    @root = Rails.root.join("storage/forge-files")
    @directory = @root.join("#{invocation.id}-#{id}")
    raise ForgeFiles::Invalid unless MODES.include?(mode)
  end

  def create
    begin
      Dir.mkdir(@root, 0o700)
    rescue Errno::EEXIST
      # A different Rails role may have made it first.
    end
    check_root!
    Dir.mkdir(@directory, 0o700)
    begin
      File.write(@directory.join("manifest"), JSON.generate([ mode, bytes, sha256 ]), mode: "wx", perm: 0o600)
      yield
    ensure
      FileUtils.remove_entry(@directory)
    end
  end

  def load
    check_root!
    direction, @bytes, @sha256 = JSON.parse(File.read(@directory.join("manifest"), 256))
    raise ActiveRecord::RecordNotFound unless direction == mode
    self.class.validate!(bytes, sha256)
  end

  def open
    file = File.open(@directory.join("verified"), File::RDONLY | File::NOFOLLOW).binmode
    block_given? ? yield(file) : file
  ensure
    file&.close if block_given?
  end

  def store(input)
    # A replay cannot replace a bundle or allocate a second in-flight partial.
    File.open(@directory.join("writer"), File::WRONLY | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
      raise ForgeFiles::Busy unless lock.flock(File::LOCK_EX | File::LOCK_NB)
      target = @directory.join("verified")
      raise ForgeFiles::Busy if target.exist?

      Tempfile.create("incoming", @directory, binmode: true) do |file|
        verify(input, file)
        yield
        file.flush
        file.chmod(0o400)
        File.link(file.path, target)
      end
    end
  end

  private
    def check_root!
      stat = @root.lstat
      raise ForgeFiles::Invalid unless stat.directory? && stat.uid == Process.euid && (stat.mode & 0o077).zero?
    end

    def verify(input, file)
      hash = Digest::SHA256.new
      total = 0
      buffer = "".b
      while (chunk = input.read([ ForgeFiles::CHUNK_BYTES, bytes - total + 1 ].min, buffer)) && !chunk.empty?
        total += chunk.bytesize
        raise ForgeFiles::Invalid if total > bytes
        hash.update(chunk)
        file.write(chunk)
      end
      raise ForgeFiles::Invalid unless total == bytes && hash.hexdigest == sha256
    end
end
