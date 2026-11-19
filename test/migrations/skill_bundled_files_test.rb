require "test_helper"
require "tmpdir"

# 20261113120000 makes a skill a folder: a table for the files beside its
# SKILL.md, and on each skill its review state and GitHub source. A skill
# already there is SKILL.md alone, so it stays ready with no files and no
# source; its files go with it. Run on a database of its own built by the
# migrations before it.
class SkillBundledFilesMigrationTest < ActiveSupport::TestCase
  VERSION = 20261113120000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("skill-files")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "an existing skill stays ready with no files or source, and a skill's files go with it" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES (1, 1, 'Maya', 'Help.', 'm', 'maya', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO skills (id, agent_id, name, description, body, created_at, updated_at) VALUES (1, 1, 'trip', 'Plans trips.', 'Steps', '#{now}', '#{now}')")
    run_migrations { it == VERSION }

    assert_equal [ [ "trip", "Steps", "ready", nil, nil ] ], @connection.select_rows("SELECT name, body, state, github_repo, github_sha FROM skills")
    insert = ->(path) { @connection.execute("INSERT INTO skill_bundled_files (skill_id, path, content, size, created_at, updated_at) VALUES (1, '#{path}', x'41', 1, '#{now}', '#{now}')") }
    insert.("references/a.md")
    assert_raises(ActiveRecord::RecordNotUnique) { insert.("references/a.md") }
    assert_equal [ [ 0 ] ], @connection.select_rows("SELECT executable FROM skill_bundled_files")

    @connection.execute("PRAGMA foreign_keys = ON")
    @connection.execute("DELETE FROM skills WHERE id = 1")
    assert_equal [ [ 0 ] ], @connection.select_rows("SELECT count(*) FROM skill_bundled_files")
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
