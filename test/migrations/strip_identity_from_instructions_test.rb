require "test_helper"
require "tmpdir"

# 20261110023741 drops the identity header agents copied into their instructions. Only
# an agent whose instructions start with one changes; each that does keeps its
# old text in a revision. Run on a database of its own built by the migrations
# before it.
class StripIdentityFromInstructionsTest < ActiveSupport::TestCase
  VERSION = 20261110023741
  HEADER = "Your name is Maya and your email address is maya@example.com. Neither can be changed.\n\nYour title is Chief of Staff.\n\n".freeze
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("strip-identity")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    insert "users", id: 1, oidc_sub: "sub-1", name: "Sam", email: "sam@example.com"
    {
      1 => HEADER + "Be brief.",                                  # one copy, with a revision of it
      2 => HEADER + HEADER + "Plan the week.",                    # two copies, no revision
      3 => "Be kind.\n\nYour name is Maya. Neither can be changed.", # the person's own words
      4 => HEADER.strip                                           # nothing else; left alone
    }.each do |id, instructions|
      insert "agents", id: id, user_id: 1, name: "Agent #{id}", instructions: instructions, model: "m", email_name: "agent#{id}"
    end
    insert "agent_revisions", agent_id: 1, instructions: HEADER + "Be brief.", model: "m", skills: '[{"name":"trip"}]'
    insert "agent_revisions", agent_id: 3, instructions: "Be kind.\n\nYour name is Maya. Neither can be changed.", model: "m"
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "only agents that start with the header change, and their old text stays in a revision" do
    run_migrations { it == VERSION }

    assert_equal [ "Be brief.", "Plan the week.", "Be kind.\n\nYour name is Maya. Neither can be changed.", HEADER.strip ],
      @connection.select_values("SELECT instructions FROM agents ORDER BY id")
    assert_equal [ HEADER + "Be brief.", "Be brief." ], revisions(1)
    assert_equal [ HEADER + HEADER + "Plan the week.", "Plan the week." ], revisions(2), "the old text is recorded first when there was none"
    assert_equal [ "Be kind.\n\nYour name is Maya. Neither can be changed." ], revisions(3)
    assert_empty revisions(4)
    assert_equal [ '[{"name":"trip"}]' ] * 2, @connection.select_values("SELECT skills FROM agent_revisions WHERE agent_id = 1"), "skills carry over"
  end

  private
    def revisions(agent_id)
      @connection.select_values("SELECT instructions FROM agent_revisions WHERE agent_id = #{agent_id} ORDER BY id")
    end

    def run_migrations
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        @connection.transaction { class_name.constantize.new(class_name, version.to_i).exec_migration(@connection, :up) }
      end
    end

    def insert(table, **values)
      now = Time.current.utc.iso8601
      columns = @connection.columns(table).map(&:name)
      values = { created_at: now, updated_at: now }.select { |column, _| columns.include?(column.to_s) }.merge(values)
      @connection.execute("INSERT INTO #{table} (#{values.keys.join(', ')}) VALUES (#{values.values.map { @connection.quote(it) }.join(', ')})")
    end
end
