require "sqlite3"

# A copy of the other install's storage folder, opened read only. Its primary
# database is the one that holds what people made; cache, queue and cable
# hold only what each install makes again for itself. Active Storage keeps
# each file under the folder at its key's first four characters.
class Workspace::Import::Source
  DATABASE = "production.sqlite3"

  attr_reader :directory

  def initialize(directory)
    @directory = Pathname(directory)
  end

  def database = directory.join(DATABASE)

  def exists? = database.file?

  # Written since its last checkpoint and not yet in the file: a copy made
  # by copying files rather than with SQLite's backup would miss it.
  def unfinished? = Pathname("#{database}-wal").then { it.file? && it.size.positive? }

  def digest = @digest ||= Digest::SHA256.file(database).hexdigest

  def version = db.get_first_value("SELECT MAX(version) FROM schema_migrations").to_s

  def tables = @tables ||= db.execute("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'").map { it["name"] }

  def table?(name) = tables.include?(name)

  def columns(table) = table?(table) ? db.execute("SELECT name FROM pragma_table_info(?)", [ table ]).map { it["name"] } : []

  def count(table) = table?(table) ? db.get_first_value("SELECT COUNT(*) FROM #{quote(table)}") : 0

  # Each row as a Hash of its column names, in id order.
  def each(table, &)
    return unless table?(table)
    db.execute("SELECT * FROM #{quote(table)} ORDER BY id", &)
  end

  def find(table, id) = db.execute("SELECT * FROM #{quote(table)} WHERE id = ?", [ id ]).first

  def values(table, column) = table?(table) ? db.execute("SELECT DISTINCT #{quote(column)} FROM #{quote(table)} WHERE #{quote(column)} IS NOT NULL").map(&:values).flatten : []

  def maximum(table, column) = table?(table) ? db.get_first_value("SELECT MAX(#{quote(column)}) FROM #{quote(table)}") : nil

  # Beside the database, as in the install's volume, or under storage/, as
  # ops/backup/durable_assistants-restore.sh unpacks a backup set.
  def file(key)
    [ directory, directory.join("storage") ].map { it.join(key[0..1], key[2..3], key) }.find(&:file?) || directory.join(key[0..1], key[2..3], key)
  end

  # The other install's sidecar store: as a backup set names its snapshot, or
  # where the volume keeps it. Its threads are carried into this sidecar's.
  def store
    [ directory.join("agent-durable.sqlite"), directory.join("agent/durable.sqlite"), directory.join("storage/agent/durable.sqlite") ].find(&:file?)
  end

  # The threads the store holds, by the sidecar's id.
  def threads
    return [] unless store
    database = SQLite3::Database.new("file:#{store.to_s.gsub(/[%?#]/) { format("%%%02x", it.ord) }}?immutable=1",
      flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI)
    database.execute("SELECT id FROM conversations").flatten.map(&:to_s)
  ensure
    database&.close
  end

  # A local computer's folder for one thread, as the sidecar made it: under
  # the agent's, by the thread's id there (agent/computers.mjs).
  def computer_folder(agent_id, durable_id)
    return unless durable_id.to_s.match?(/\A\d+\z/)
    [ directory, directory.join("storage") ].map { it.join("agent/computers", "bot-#{Integer(agent_id)}", durable_id.to_s) }.find(&:directory?)
  end

  def close = @db&.close

  private
    # Immutable: SQLite neither locks the copy nor makes its -shm and -wal
    # files beside it, which even a read only connection does to a database
    # left in WAL mode, as a backup of a live one is.
    def db
      @db ||= SQLite3::Database.new("file:#{database.to_s.gsub(/[%?#]/) { format("%%%02x", it.ord) }}?immutable=1",
        flags: SQLite3::Constants::Open::READONLY | SQLite3::Constants::Open::URI, results_as_hash: true)
    end

    def quote(name) = %("#{name.to_s.gsub('"', '""')}")
end
