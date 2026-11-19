require "zip"

# A skill's folder before it is a skill: its SKILL.md and the files beside
# it, from an uploaded folder, a zip or GitHub, checked the same way
# whichever it came from (docs/skills.md). Nothing in it is run here.
class Skill::Folder
  MARKDOWN = "SKILL.md"
  FILES = 100 # beside SKILL.md
  FILE_BYTES = 1.megabyte
  BYTES = 5.megabytes
  # A tar's ustar header holds a path this many bytes long, split at a slash.
  PATH_LENGTH = 150
  NAME_LENGTH = 100
  # What an operating system leaves in a folder it zips.
  LITTER = %r{(?:\A|/)(?:__MACOSX/|\.DS_Store\z|Thumbs\.db\z|desktop\.ini\z)}

  class Invalid < StandardError; end

  # executable: whether its mode says so; the folder decides the rest (#executable?).
  Entry = Data.define(:path, :content, :executable) do
    def size = content.bytesize
  end

  def self.text?(bytes)
    bytes = bytes.to_s
    !bytes.include?("\0") && bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding?
  end

  def self.git_sha(bytes) = Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes.b)

  # A script's name, though nothing marks it to run: `python x.py` runs it anyway.
  SCRIPT = /\.(?:sh|bash|zsh|fish|py|js|mjs|cjs|ts|rb|pl|php|lua|ps1|bat|cmd|exe|so|jar)\z/i

  # A file is a program if anything says so: its mode, a shebang, a Linux
  # binary's first bytes, a script's name, or the spec's scripts/ folder.
  def self.executable?(path, content, mode = false)
    mode || path.start_with?("scripts/") || path.match?(SCRIPT) || content.b.start_with?("#!", "\x7FELF".b)
  end

  # What a browser sends for a chosen folder: each file, and its path inside
  # the folder, which the page reads from the browser (skill_folder_controller).
  def self.from_uploads(files, paths = [])
    raise Invalid, "Choose a folder or a zip." if files.empty?
    return from_zip(files.first) if files.one? && zip?(files.first)
    raise Invalid, too_many(files.size) if files.size > FILES + 1
    entries = files.each_with_index.map do |file, index|
      path = paths[index].presence || file.original_filename
      raise Invalid, too_big(path) if file.size > FILE_BYTES
      content = file.read.b
      Entry.new(path, content, false)
    end
    new(entries)
  end

  def self.zip?(file) = File.extname(file.original_filename.to_s).casecmp?(".zip")

  # Each entry is read only up to the limit, whatever its header claims, so a
  # small zip that unpacks to gigabytes is refused at the first megabyte.
  def self.from_zip(file)
    raise Invalid, "The zip is #{size(file.size)}; it may be at most #{size(BYTES)}." if file.size > BYTES
    entries = []
    Zip::File.open_buffer(file.read) do |zip|
      files = zip.entries.reject(&:directory?)
      raise Invalid, too_many(files.size) if files.size > (FILES + 1) * 2
      total = 0
      files.each do |entry|
        raise Invalid, "#{entry.name} is a link; a skill's files must be real files." if entry.symlink?
        content = entry.get_input_stream { it.read(FILE_BYTES + 1) }.to_s.b
        raise Invalid, too_big(entry.name) if content.bytesize > FILE_BYTES
        raise Invalid, too_large if (total += content.bytesize) > BYTES
        entries << Entry.new(entry.name, content, entry.unix_perms.to_i.anybits?(0o111))
      end
    end
    new(entries)
  rescue Zip::Error
    raise Invalid, "That zip couldn't be opened. Make it again and upload it."
  end

  def self.size(bytes) = ActiveSupport::NumberHelper.number_to_human_size(bytes)
  def self.too_many(count) = "That folder has #{count} files; a skill may have at most #{FILES} beside its SKILL.md."
  def self.too_big(path) = "#{path} is over #{size(FILE_BYTES)}, the most one file in a skill may be."
  def self.too_large = "That folder is over #{size(BYTES)}, the most a skill may be."

  attr_reader :entries

  def initialize(entries)
    entries = entries.map { it.with(path: it.path.to_s.delete_prefix("./")) }.reject { it.path.end_with?("/") || it.path.match?(LITTER) }
    entries.each { |entry| raise Invalid, "#{entry.path.inspect} isn't a path inside the folder." unless safe?(entry.path) }
    @entries = without_top_folder(entries).map { it.with(executable: self.class.executable?(it.path, it.content, it.executable)) }.sort_by(&:path)
    check
  end

  def markdown = skill_md.content.dup.force_encoding(Encoding::UTF_8)

  # Every file but SKILL.md.
  def bundled = entries.reject { it.path == MARKDOWN }

  def bytes = entries.sum(&:size)

  private
    # Relative, without `..`, `.` or empty steps, backslashes or control
    # characters: each file lands inside the skill's folder, wherever that is.
    def safe?(path)
      path.present? && path.bytesize <= PATH_LENGTH && !path.start_with?("/") && !path.match?(/[\\\p{Cc}]|\A[a-z]:/i) &&
        path.split("/", -1).none? { it.in?([ "", ".", ".." ]) || it.bytesize > NAME_LENGTH }
    end

    # A folder zipped or chosen whole arrives inside its own name.
    def without_top_folder(entries)
      return entries if entries.empty? || entries.any? { it.path == MARKDOWN }
      top = entries.first.path.split("/").first
      return entries unless entries.all? { it.path.start_with?("#{top}/") }
      entries.map { it.with(path: it.path.delete_prefix("#{top}/")) }
    end

    def skill_md = entries.find { it.path == MARKDOWN }

    # A file whose name is also another file's folder, such as a and a/b: no
    # computer can hold both.
    def file_and_folder
      paths = entries.map(&:path)
      paths.find { |path| paths.any? { it.start_with?("#{path}/") } }
    end

    def check
      raise Invalid, "There is no SKILL.md at the top of that folder. A skill is a folder with its SKILL.md at the top." unless skill_md
      raise Invalid, "SKILL.md isn't text. It must be Markdown, with the skill's name and description at the top." unless self.class.text?(skill_md.content)
      raise Invalid, "#{entries.map(&:path).tally.find { _2 > 1 }.first} is in the folder twice." if entries.map(&:path).uniq.size < entries.size
      clash = file_and_folder
      raise Invalid, "#{clash} is both a file and a folder in that folder." if clash
      raise Invalid, self.class.too_many(bundled.size) if bundled.size > FILES
      big = entries.find { it.size > FILE_BYTES }
      raise Invalid, self.class.too_big(big.path) if big
      raise Invalid, self.class.too_large if bytes > BYTES
    end
end
