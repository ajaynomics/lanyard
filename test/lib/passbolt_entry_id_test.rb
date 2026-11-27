require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# A sign-in fetched by name keeps only its entry's id, so the next fetch reads
# that one entry instead of listing the whole vault first. An id that stops
# working is dropped and the name looked up once more.
class PassboltEntryIdTest < ActiveSupport::TestCase
  include AgentTestHelper
  include PassboltTestHelper

  setup do
    install_fake_passbolt
    @agent = create_user(name: "Alice").agents.sole
    @cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
  end
  teardown do
    Rails.cache = @cache
    remove_fake_passbolt
  end

  test "a second fetch by the same name reads the one entry without listing the vault" do
    assert_equal PASSWORD, DurableAssistants::Passbolt.sign_in_by_name(@agent, "Bank").password
    assert_equal [ 1, 1 ], counts

    File.write(@passbolt_calls, "")
    assert_equal PASSWORD, DurableAssistants::Passbolt.sign_in_by_name(@agent, "bank").password
    assert_equal [ 0, 1 ], counts, "one read, no list"
  end

  test "the cache holds the entry's id and nothing else, per holder and name" do
    DurableAssistants::Passbolt.sign_in_by_name(@agent, "Bank")

    assert_equal "7f0c", Rails.cache.read(key)
    assert_nil Rails.cache.read([ "vault-entry-id", "Workspace", @agent.workspace.id, "bank" ]), "a workspace keeps its own"
  end

  test "a kept id the vault no longer answers for is dropped, and the name looked up once more" do
    Rails.cache.write(key, "gone")
    path = File.join(@passbolt_dir, "passbolt")
    File.write(path, File.read(path).sub('case "$1 $2" in', %{case "$*" in *"--id gone"*) exit 1 ;; esac\ncase "$1 $2" in}))

    assert_equal PASSWORD, DurableAssistants::Passbolt.sign_in_by_name(@agent, "Bank").password
    assert_equal [ 1, 2 ], counts, "the failed read, then one list and one read"
    assert_equal "7f0c", Rails.cache.read(key)
  end

  test "a kept id whose entry now has another name is dropped, not filled under the old one" do
    Rails.cache.write([ "vault-entry-id", "Agent", @agent.id, "old bank" ], "7f0c")

    assert_raises(DurableAssistants::Passbolt::Error) { DurableAssistants::Passbolt.sign_in_by_name(@agent, "Old bank") }
    assert_nil Rails.cache.read([ "vault-entry-id", "Agent", @agent.id, "old bank" ])
  end

  test "a vault that cannot be reached raises, and nothing is kept" do
    remove_fake_passbolt
    install_fake_passbolt(fail: true)

    assert_raises(DurableAssistants::Passbolt::Error) { DurableAssistants::Passbolt.sign_in_by_name(@agent, "Bank") }
    assert_nil Rails.cache.read(key)
  end

  private
    def key = [ "vault-entry-id", "Agent", @agent.id, "bank" ]

    def counts = [ passbolt_calls.scan(/^ARGS list /).size, passbolt_calls.scan(/^ARGS get /).size ]
end
