require "test_helper"
require "tmpdir"

# 20261112000000 adds payment requests and each person's Link sign-in. The
# people and calls already there are as they were, with no wallet connected;
# a call has at most one payment request. Run on a database of its own built
# by the migrations before it.
class PaymentRequestsTest < ActiveSupport::TestCase
  VERSION = 20261112000000
  self.use_transactional_tests = false

  class Scratch < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @verbose, ActiveRecord::Migration.verbose = ActiveRecord::Migration.verbose, false
    @directory = Dir.mktmpdir("payment-requests")
    Scratch.establish_connection(adapter: "sqlite3", database: File.join(@directory, "scratch.sqlite3"))
    @connection = Scratch.lease_connection
    run_migrations { it < VERSION }
  end

  teardown do
    Scratch.remove_connection
    FileUtils.remove_entry(@directory)
    ActiveRecord::Migration.verbose = @verbose
  end

  test "people and calls already there are as they were, with no wallet, and a call has one payment request at most" do
    now = Time.current.utc.iso8601
    @connection.execute("INSERT INTO users (id, oidc_sub, name, email, created_at, updated_at) VALUES (1, 's', 'Maya', 'maya@example.com', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO agents (id, user_id, name, instructions, model, email_name, created_at, updated_at) VALUES (1, 1, 'Maya', 'Help.', 'm', 'maya', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO conversations (id, user_id, agent_id, request_id, title, status, listed_at, created_at, updated_at) VALUES (1, 1, 1, 'r', 'Trip', 'idle', '#{now}', '#{now}', '#{now}')")
    @connection.execute("INSERT INTO invocations (id, conversation_id, task_id, call_id, tool_name, digest, state, created_at, updated_at) VALUES (1, 1, '7', 'c1', 'current_time', 'd', 'succeeded', '#{now}', '#{now}')")
    run_migrations { it == VERSION }

    assert_equal [ [ 1, "Maya", nil ] ], @connection.select_rows("SELECT id, name, link_session FROM users")
    assert_equal [ [ 1, "succeeded" ] ], @connection.select_rows("SELECT id, state FROM invocations")
    insert = -> { @connection.execute("INSERT INTO payment_requests (invocation_id, amount, currency, payee, checkout_url, reason, created_at, updated_at) VALUES (1, 1250, 'usd', 'Acme', 'https://example.com/pay', 'Tickets', '#{now}', '#{now}')") }
    insert.()
    assert_equal [ [ "requested", nil ] ], @connection.select_rows("SELECT state, next_ask_at FROM payment_requests")
    assert_raises(ActiveRecord::RecordNotUnique) { insert.() }
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
