# The diff of the copy against what came, table by table: how many rows the
# copy holds, how many came and how many stayed behind, and a checksum of
# every column written, read back from this install's database (an
# encrypted column decrypted with this install's keys) and from the copy
# (with the other's, each reference as the id it became here). Equal
# checksums and every row accounted for, or the import is undone.
class Workspace::Import::Check
  Result = Data.define(:table, :source, :imported, :left, :source_checksum, :checksum) do
    def matches? = imported == source - left && source_checksum == checksum

    def to_s
      format("%-28s %8d in the copy %8d came %8d stayed  checksum %s", table, source, imported, left,
        matches? ? "ok #{checksum.first(12)}" : "DIFFERS: copy #{source_checksum.first(12)}, here #{checksum.first(12)}")
    end

    def to_h = super.merge(matches: matches?).transform_keys(&:to_s)
  end

  BATCH = 500

  def initialize(run)
    @run = run
  end

  def results
    [ people, memberships, *Workspace::Import::Table.all.select { source.table?(it.name) }.map { table(it) }, files ]
  end

  private
    def source = @run.source

    # By sign-in subject, as they were matched: a person already here keeps the email they have here.
    def people
      there = []
      source.each("users") { |row| there << [ @run.id("users", row["id"]), row["oidc_sub"] ] }
      here = User.where(id: @run.ids("users").values).pluck(:id, :oidc_sub) # tenancy-ok: the people this import matched or made
      result("users", source.count("users"), there, here)
    end

    def memberships
      there = @run.ids("users").values.uniq.map { [ it ] }
      result("workspace_memberships", there.size, there, @run.workspace.memberships.pluck(:user_id).map { [ it ] })
    end

    def table(table)
      columns = table.columns(source)
      there = []
      source.each(table.name) do |row|
        next unless (id = @run.id(table.name, row["id"]))
        there << [ id, *table.values(row, @run, final: true).values_at(*columns) ]
      end
      result(table.name, source.count(table.name), there, here(table, columns))
    end

    def here(table, columns)
      connection = table.model.connection
      @run.ids(table.name).values.each_slice(BATCH).flat_map do |ids|
        connection.select_rows("SELECT id, #{columns.map { connection.quote_column_name(it) }.join(", ")} FROM #{connection.quote_table_name(table.name)} WHERE id IN (#{ids.map { Integer(it) }.join(", ")})")
      end.map { |id, *values| [ id, *columns.zip(values).map { |column, value| table.encrypted?(column) ? table.plaintext(column, value) : value } ] }
    end

    def files
      name = Workspace::Import::Files::NAME
      result(name, source.count(name), Workspace::Import::Files.there(@run), Workspace::Import::Files.here(@run.ids(name).values))
    end

    def result(table, count, there, here)
      Result.new(table:, source: count, imported: here.size, left: @run.left(table).values.sum, source_checksum: checksum(there), checksum: checksum(here))
    end

    # Of each row's digest, in id order: a large table's rows are not all held at once.
    def checksum(rows)
      Digest::SHA256.hexdigest(rows.map { [ it.first, Digest::SHA256.hexdigest(JSON.generate(it.map { canonical(it) })) ] }.sort.join("\n"))
    end

    def canonical(value)
      case value
      when true then 1
      when false then 0
      when String then value.encoding == Encoding::BINARY ? "hex:#{value.unpack1("H*")}" : value
      else value
      end
    end
end
