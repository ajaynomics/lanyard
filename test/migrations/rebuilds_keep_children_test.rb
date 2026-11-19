require "test_helper"
require "tmpdir"

# A migration that makes SQLite rebuild a table (a foreign key added or
# removed, a column changed or removed) drops the old table. If foreign keys
# are still on then, as they are inside a migration's transaction, every key
# that cascades from that table deletes its rows and every nullifying one
# empties its column (PayerRebuildMigrationTest). Such a migration needs
# `disable_ddl_transaction!`, so Rails' switch turning them off holds. This
# runs every migration as `bin/rails db:migrate` does and fails on any drop
# that would take children with it.
class RebuildsKeepChildrenTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("rebuilds-keep-children")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "no migration drops a table while a cascading or nullifying key still points at it" do
    drops = []
    watch_drops = ->(*, payload) do
      next unless payload[:connection] == @connection && payload[:sql] =~ /\ADROP TABLE "?(\w+)"?/
      dropped = $1
      next if @connection.select_value("PRAGMA foreign_keys").zero?
      children = @connection.tables.select do |table|
        @connection.select_rows("PRAGMA foreign_key_list(#{@connection.quote_table_name(table)})")
          .any? { |_, _, parent, _, _, _, on_delete| parent == dropped && on_delete.in?([ "CASCADE", "SET NULL" ]) }
      end
      drops << "#{@version} drops #{dropped}, taking #{children.join(', ')}" if children.any?
    end

    ActiveSupport::Notifications.subscribed(watch_drops, "sql.active_record") { run_migrations }

    assert_empty drops
  end

  private
    def run_migrations
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        @version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        class_name = name.sub(/\..+\z/, "").camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        migration = class_name.constantize.new(class_name, @version.to_i)
        if migration.disable_ddl_transaction
          migration.exec_migration(@connection, :up)
        else
          @connection.transaction { migration.exec_migration(@connection, :up) }
        end
      end
    end
end
