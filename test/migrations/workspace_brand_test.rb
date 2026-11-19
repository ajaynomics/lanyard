require "test_helper"
require "tmpdir"

# 20261119010000 lets a workspace go by its own name, colour and link host.
# Existing workspaces have none, so each still goes by the install's, as
# before. Run on a database of its own built by the migrations before it.
class WorkspaceBrandMigrationTest < ActiveSupport::TestCase
  VERSION = 20261119010000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("workspace-brand")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
    @now = Time.current.utc.iso8601
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "existing workspaces set no name, colour or link host of their own, and keep everything else" do
    @connection.execute "INSERT INTO workspaces (id, name, personal, created_at, updated_at) VALUES (1, 'Team', 0, '#{@now}', '#{@now}'), (2, NULL, 1, '#{@now}', '#{@now}')"
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Team", 0, nil, nil, nil ], [ 2, nil, 1, nil, nil, nil ] ],
      @connection.select_rows("SELECT id, name, personal, app_name, accent_hue, link_host FROM workspaces ORDER BY id")
  end

  private
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
end
