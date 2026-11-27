require "test_helper"
require "tmpdir"
require_relative "../../test_helpers/agent_test_helper"

# Another install of this app, at an older release (488e963, schema
# 20261115040000), comes in as a shared workspace: its people, agents, threads
# and files, with every id remapped and every secret re-encrypted under this
# install's keys. Its copy is built here from that release's schema, as the
# operator would hand over a copy of its storage folder.
class Workspace::ImportTest < ActiveSupport::TestCase
  include AgentTestHelper

  SCHEMA = Rails.root.join("test/models/workspace/import/schema_20261115040000.rb")
  # The other install's own encryption keys, as its credentials would hold them. Made up.
  SOURCE_KEYS = { primary_key: "made-up-primary-key-of-the-other-install", key_derivation_salt: "made-up-salt-of-the-other-install" }.freeze
  NOW = Time.utc(2026, 11, 10, 9, 30, 15, 123456)

  self.use_transactional_tests = false

  class Copy < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @directory = Dir.mktmpdir("workspace-import")
    Copy.establish_connection(adapter: "sqlite3", database: File.join(@directory, "production.sqlite3"))
    @copy = Copy.lease_connection
    load_source_schema
    @maya = User.create!(oidc_sub: "sub-maya", email: "maya@example.com", name: "Maya Here")
    @maya.personal_workspace
  end

  teardown do
    Copy.remove_connection
    FileUtils.remove_entry(@directory)
    remove_sidecar_settings
    ActiveStorage::Blob.find_each(&:purge)
    connection = ActiveRecord::Base.connection
    connection.disable_referential_integrity do
      connection.tables.excluding("schema_migrations", "ar_internal_metadata").each { connection.execute("DELETE FROM #{it}") }
    end
  end

  test "a newer copy remaps reporting IDs before validation" do
    build_install
    @copy.execute("ALTER TABLE agents ADD COLUMN parent_id INTEGER")
    @copy.execute("UPDATE agents SET parent_id = 2 WHERE id = 1")
    @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    2.times { |index| @maya.start_agent("Already here #{index}") }

    imported = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "Maya@example.com").workspace
    scout = imported.agents.find_by!(name: "Scout")
    ledger = imported.agents.find_by!(name: "Ledger")
    assert_not_equal 2, ledger.id
    assert_equal ledger, scout.manager
    assert_nil ledger.parent_id
  end

  test "a newer copy keeps instruction history without its install's call link" do
    build_install
    @copy.execute("ALTER TABLE agent_revisions ADD COLUMN invocation_id INTEGER")
    @copy.execute("UPDATE agent_revisions SET invocation_id = 1 WHERE id = 1")
    @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "Maya@example.com")
    revision = import.workspace.agents.find_by!(name: "Scout").revisions.sole
    assert_equal "Find things.", revision.instructions
    assert_nil revision.invocation_id
  end

  test "the importer refuses a reporting cycle instead of writing it" do
    build_install
    @copy.execute("ALTER TABLE agents ADD COLUMN parent_id INTEGER")
    @copy.execute("UPDATE agents SET parent_id = CASE id WHEN 1 THEN 2 ELSE 1 END")
    @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    assert_raises(Workspace::Import::Refused) do
      Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "Maya@example.com")
    end
  end

  test "the other install comes in as a shared workspace, record by record, with ids remapped and secrets re-encrypted" do
    build_install
    before = Digest::SHA256.file(source_database).hexdigest

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "Maya@Example.com", name: "Old office")

    assert_equal before, Digest::SHA256.file(source_database).hexdigest, "the copy is never written"

    workspace = import.workspace
    assert_equal "Old office", workspace.name
    assert_not workspace.personal?
    omar = User.find_by!(email: "omar@example.com")
    assert_equal @maya, workspace.owner, "matched by sign-in subject, whatever their email there"
    assert_equal({ @maya => "owner", omar => "member" }, workspace.memberships.to_h { [ it.user, it.role ] })
    assert_equal 2, User.count
    assert_carried "users", 2, omar, except: %w[ ssh_keyring link_session ]
    assert_nil omar.ssh_keyring, "a key held by the other install's sidecar is not this one's"
    assert_equal({ "refresh_token" => "made-up-link-refresh" }, omar.link_session)
    assert_equal "Maya Here", @maya.reload.name, "a person already here keeps their own settings"

    scout, ledger = workspace.agents.order(:name).to_a.values_at(1, 0)
    assert_carried "agents", 1, scout, except: %w[ user_id mail_to_agent_id passbolt_passphrase caldav_password ]
    assert_carried "agents", 2, ledger, except: %w[ user_id ]
    assert_equal [ @maya, omar ], [ scout.user, ledger.user ]
    assert_equal ledger, scout.mail_to_agent
    assert_nil scout.parent_id
    assert_nil ledger.parent_id
    assert_equal "made-up-passphrase", scout.passbolt_passphrase
    assert_equal "made-up-caldav-password", scout.caldav_password
    assert_equal "scout", scout.caldav_username
    assert_equal "https://calendar.example.com/family/", scout.linked_calendar_server
    assert_nil scout.own_instruction_approval, "an old release does not specify an override"
    assert scout.asks_own_instruction_change?

    assert_carried "agent_revisions", 1, scout.revisions.sole, except: %w[ agent_id ]
    assert_carried "notes", 1, scout.notes.sole, except: %w[ agent_id ]
    assert_carried "prompts", 1, scout.prompts.sole, except: %w[ agent_id ]
    skill = scout.skills.sole
    assert_carried "skills", 1, skill, except: %w[ agent_id ]
    assert_carried "skill_bundled_files", 1, skill.files.sole, except: %w[ skill_id ]
    document = scout.documents.sole
    assert_carried "documents", 1, document, except: %w[ agent_id seen_version_id ]
    assert_carried "document_versions", 1, document.versions.sole, except: %w[ document_id ]
    assert_equal document.versions.sole.id, document.seen_version_id
    assert_carried "routines", 1, scout.routines.sole, except: %w[ agent_id ]
    permission = scout.permissions.sole
    assert_carried "permissions", 1, permission, except: %w[ agent_id granted_by_id ]
    assert_equal omar.id, permission.granted_by_id
    assert_carried "computers", 1, scout.computer, except: %w[ agent_id ]
    assert_carried "computers", 2, ledger.computer, except: %w[ agent_id ]
    assert_equal "agent-#{ledger.id}", ledger.computer.ssh_keyring, "its SSH key is the agent's own here, never a person's id from there"
    concourse = scout.concourse_agents.sole
    assert_carried "concourse_agents", 1, concourse, except: %w[ agent_id client_secret push_token ]
    assert_equal "made-up-client-secret", concourse.client_secret
    bot = ledger.campfire_bot
    # askers is no longer kept (#258), so it isn't carried.
    assert_carried "campfire_bots", 1, bot, except: %w[ agent_id bot_key askers ]
    assert_equal "7-madeupbotkey", bot.bot_key

    connector = workspace.mcp_servers.find_by!(name: "crm")
    assert_carried "mcp_servers", 1, connector, except: %w[ user_id token headers sign_in_needed refresh_error ]
    assert_nil connector.token, "a key pasted there is the owner's to give again here"
    assert_nil connector.headers
    assert_equal @maya, connector.user
    assert_not workspace.mcp_servers.exists?(name: "wiki"), "the other install's own install connector stays there"
    assert_not workspace.mcp_servers.exists?(name: "books"), "another person's connector is theirs to set up again"
    assert_not workspace.mcp_servers.exists?(name: "old"), "a connector switched off there stays"
    gmail = workspace.mcp_servers.find_by!(name: "gmail")
    assert_nil gmail.oauth_tokens, "a sign-in made through the other install's client is not this one's"
    assert gmail.needs_sign_in?, "the owner signs in again here"
    assert_equal({ "the other install's own connector to its wiki or CRM: a workspace here turns on this install's own" => 1,
      "another person's: the owner imports only their own" => 1, "switched off there" => 1 }, import.report.dig("left", "mcp_servers"))
    assert_equal [ connector ], Agent::CoreConnector.where(agent: scout).map(&:mcp_server)

    thread = scout.conversation
    assert_carried "conversations", 1, thread, except: %w[ user_id agent_id durable_id last_entry_id ]
    assert_nil thread.durable_id, "the other sidecar's thread is not in this one's store"
    assert_nil thread.last_entry_id
    branch = scout.conversations.where.not(parent_id: nil).sole
    assert_equal [ thread.id, thread.id ], [ branch.parent_id, branch.root_id ]
    thread_connector = thread.mcp_servers.sole
    assert_carried "mcp_servers", 3, thread_connector, except: %w[ user_id conversation_id token headers sign_in_needed refresh_error ]

    messages = thread.messages.order(:entry_id).to_a
    assert_equal [ "Hello Scout", "Hello Maya" ], messages.map(&:content)
    assert messages.map(&:entry_id).all?(&:negative?), "the other store's entries sort before any this store makes"
    assert_equal messages.map { it.entry_id.to_s }, messages.map(&:entry_key)
    assert_equal messages.first.entry_id, branch.forked_at_entry_id
    messages.zip([ 1, 2 ]).each { |message, id| assert_carried "messages", id, message, except: %w[ conversation_id entry_id entry_key ] }
    assert_equal "a picture of the whiteboard", messages.first.images.sole.download

    invocation = thread.invocations.sole
    assert_carried "invocations", 1, invocation, except: %w[ conversation_id ]
    assert_carried "approvals", 1, invocation.approval, except: %w[ invocation_id decided_by_id ]
    assert_equal @maya.id, invocation.approval.decided_by_id
    upload = thread.uploads.sole
    assert_carried "uploads", 1, upload, except: %w[ conversation_id ]
    assert_equal "the bytes of a report", upload.file.download
    assert_carried "peer_tasks", 1, thread.peer_tasks.sole, except: %w[ conversation_id concourse_agent_id notes_followed ]
    assert_equal concourse, thread.peer_tasks.sole.concourse_agent
    assert_not thread.peer_tasks.sole.notes_followed?, "as the migration that added it marks a task from before"

    assert import.check.all?(&:matches?), import.check.reject(&:matches?).map(&:to_s).join("\n")
    assert_includes import.check.map(&:table), "messages"
  end

  test "an install at this release brings its agents' mail accounts, calendar servers and Telegram bot with the posts it heard, and its workspaces fold into one" do
    build_install
    migrate_source { it > 20261115040000 }
    insert "agent_mail_accounts", id: 1, agent_id: 1, address: "scout@mail.example.com", display_name: "Scout", smtp_host: "smtp.example.com",
      imap_host: "imap.example.com", vault_entry: "Scout mail", forced_bcc: "archive@example.com", primary: true, inbox_last_uid: 7
    insert "agent_mail_accounts", id: 2, agent_id: 1, address: "former@mail.example.com", imap_host: "imap.example.com", vault_entry: "Former mail", read_only: true
    insert "agent_mail_account_folders", id: 1, mail_account_id: 2, name: "INBOX", validity: 3, last_uid: 40
    insert "agent_calendar_servers", id: 1, agent_id: 2, url: "https://dav.example.com/calendars/ledger/", vault_entry: "Ledger calendar"
    insert "telegram_bots", id: 1, agent_id: 2, vault_entry: "Ledger bot", username: "ledger_bot", webhook_secret: encrypt("made-up-webhook-secret"), chats: json({ "5" => "Omar" })
    insert "telegram_messages", id: 1, telegram_bot_id: 1, chat_id: 5, message_id: 9, sender: "Omar", text: "The books close Friday.", sent_at: "2026-11-16 20:00:00"
    @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    # As ops/backup/durable_assistants-restore.sh unpacks a backup set: the files under storage/.
    FileUtils.mkdir_p(File.join(@directory, "storage"))
    FileUtils.mv(File.join(@directory, "ma"), File.join(@directory, "storage"))

    omar = User.create!(oidc_sub: "sub-omar", email: "omar@here.example.com", name: "Omar Here")

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "omar@example.com", name: "Old office")

    workspace = import.workspace
    scout, ledger = workspace.agents.find_by!(email_name: "scout-there"), workspace.agents.find_by!(email_name: "ledger-there")
    assert_equal omar, workspace.owner, "the same sign-in, whatever their email here"
    sending, reading = scout.mail_accounts.order(:read_only).to_a
    assert_carried "agent_mail_accounts", 1, sending, except: %w[ agent_id ]
    assert_carried "agent_mail_accounts", 2, reading, except: %w[ agent_id ]
    assert_carried "agent_mail_account_folders", 1, reading.folders.sole, except: %w[ mail_account_id ]
    assert_equal sending, scout.mail_account
    assert_carried "agent_calendar_servers", 1, ledger.calendar_server, except: %w[ agent_id ]
    assert_carried "telegram_bots", 1, ledger.telegram_bot, except: %w[ agent_id webhook_secret ]
    assert_equal "made-up-webhook-secret", ledger.telegram_bot.webhook_secret
    assert_carried "telegram_messages", 1, ledger.telegram_bot.messages.sole, except: %w[ telegram_bot_id ]
    assert_equal [ workspace ], Agent.where(email_name: %w[ scout-there ledger-there ]).map(&:workspace).uniq
    assert_empty scout.conversation.mcp_servers, "Maya's thread connector is hers to set up again"
    assert_equal "Hello Scout", scout.conversation.messages.order(:entry_id).first.content
    assert_equal "a picture of the whiteboard", scout.conversation.messages.order(:entry_id).first.images.sole.download
    assert import.check.all?(&:matches?), import.check.reject(&:matches?).map(&:to_s).join("\n")
    assert_equal 2, import.report.dig("stays", "workspaces"), "its people's own workspaces stay there; their agents are all in this one"
  end

  test "no connector of any kind brings a sign-in or a key; each one that held one is listed to reconnect, here and on the Connectors page" do
    build_install
    insert "mcp_servers", id: 7, user_id: 1, name: "slack", url: "https://slack.example.com/mcp", oauth_client: encrypt({ "client_id" => "made-up-client" }.to_json),
      oauth_pending: encrypt({ "verifier" => "made-up-verifier" }.to_json), oauth_state: "made-up-state", tools: json([]), args: json([]), disabled_tools: json([])
    insert "mcp_servers", id: 8, user_id: 1, name: "files", command: "npx", args: json(%w[ files-server ]), env: encrypt({ "API_KEY" => "made-up-env-key" }.to_json),
      tools: json([]), disabled_tools: json([])
    insert "mcp_servers", id: 9, user_id: 1, name: "mail", url: "imaps://maya%40example.com@imap.example.com:993", token: encrypt("made-up-mail-password"),
      tools: json([]), args: json([]), disabled_tools: json([])
    insert "mcp_servers", id: 10, user_id: 1, name: "x", url: McpServer::X::URL, token: encrypt({ "consumer_key" => "made-up-x-key" }.to_json),
      tools: json([]), args: json([]), disabled_tools: json([])
    insert "mcp_servers", id: 11, user_id: 1, name: "docs", url: "https://docs.example.com/mcp", tools: json([]), args: json([]), disabled_tools: json([])
    insert "mcp_servers", id: 12, user_id: 2, name: "ledger", url: "https://ledger.example.com/mcp", token: encrypt("made-up-ledger-token"), tools: json([]), args: json([]), disabled_tools: json([])
    @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")

    connectors = McpServer.where(workspace: import.workspace) # tenancy-ok: every connector the import made, thread ones too
    assert_equal %w[ crm docs files gmail mail notes slack x ], connectors.map(&:name).sort, "only Maya's own, switched on, and not the install's"
    connectors.each do |connector|
      assert_equal [ nil ] * 7, connector.attributes.values_at(*%w[ token headers env oauth_client oauth_tokens oauth_pending oauth_state ]), connector.name
    end
    assert_empty McpServer.where(name: %w[ books old ledger wiki ]), "another person's, switched off, and the install's own stay there" # tenancy-ok: nowhere here

    reconnect = import.report["reconnect"].to_h { [ it["name"], it["how"] ] }
    assert_equal %w[ crm files gmail mail notes slack x ], reconnect.keys.sort, "each that held a sign-in or a key; docs needed neither"
    assert_equal "sign in again", reconnect["gmail"]
    assert_equal "sign in again", reconnect["slack"]
    assert_match(/add it again with its key/, reconnect["crm"])
    assert_match(/Reconnect: gmail, sign in again/, import.summary)
    assert_match(/Reconnect: files, add it again with its key/, import.summary)

    gmail, crm, docs = %w[ gmail crm docs ].map { connectors.find_by!(name: it) }
    assert_equal "needs_sign_in", gmail.status
    assert_match(/Sign in again/, ApplicationController.render(partial: "connectors/fix", locals: { connector: gmail }), "one click on the Connectors page")
    assert crm.needs_attention?, "the Connectors page names it and why"
    assert_match(/its key stayed with the other install/, crm.refresh_error)
    assert_not docs.needs_attention?
  end

  test "two of the owner's connectors with one name, from two of the copy's workspaces, are refused before anything is written, rehearsal or not" do
    build_install
    migrate_source { it > 20261115040000 }
    insert "workspaces", id: 10, name: "Side project", personal: false
    insert "workspace_memberships", id: 10, workspace_id: 10, user_id: 1, role: "owner"
    insert "mcp_servers", id: 20, user_id: 1, workspace_id: 10, name: "crm", url: "https://other-crm.example.com/mcp", tools: json([]), args: json([]), disabled_tools: json([])
    insert "mcp_servers", id: 21, user_id: 1, workspace_id: 10, name: "old", url: "https://old.example.com/mcp", tools: json([]), args: json([]), disabled_tools: json([])
    @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    keys = Workspace::Import::Keys.new(**SOURCE_KEYS)

    [ true, false ].each do |rehearse|
      error = assert_no_difference [ -> { Workspace.count }, -> { Agent.count }, -> { McpServer.count } ] do
        assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", name: "Old office", rehearse:) }
      end
      assert_match(%r{the connector crm comes from two of the copy's workspaces, .+ \(https://crm.example.com/mcp\) and Side project \(https://other-crm.example.com/mcp\)}, error.message)
      assert_match(/rename or switch off one of them there first/, error.message)
      assert_no_match(/connector old/, error.message, "one switched off there stays, so it cannot clash")
    end
  end

  test "a workspace here that already holds an import is refused before anything is written" do
    build_install
    office = Workspace.create!(name: "Office").tap { it.memberships.create!(user: @maya, role: "owner") }
    Workspace::Import.create!(workspace: office, source_digest: "made-up-digest", source_version: "20261115040000")

    error = assert_no_difference -> { Agent.count } do
      assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", into: office) }
    end
    assert_match(/Office already holds another install's import: import into a new workspace/, error.message)
  end

  test "the task prints the report, reads the keys from a file, never shows them, and a rehearsal keeps nothing" do
    build_install
    keys = File.join(@directory, "keys.yml").tap { File.write(it, { "active_record_encryption" => SOURCE_KEYS.transform_keys(&:to_s) }.to_yaml) }
    Rails.application.load_tasks unless Rake::Task.task_defined?("workspaces:import")
    task = ->(**env) do
      env = env.transform_keys(&:to_s)
      previous = env.keys.index_with { ENV[it] }
      env.each { |name, value| ENV[name] = value }
      capture_io { Rake::Task["workspaces:import"].execute }.first
    ensure
      previous.each { |name, value| ENV[name] = value }
    end

    before = [ Workspace.count, Agent.count, ActiveStorage::Blob.count ]
    rehearsal = task.(SOURCE: @directory, SOURCE_KEYS: keys, OWNER: "maya@example.com", NAME: "Old office", REHEARSE: "1")

    assert_match(/^messages\s+2 in the copy\s+2 came\s+0 stayed  checksum ok/, rehearsal)
    assert_match(/^mcp_servers\s+6 in the copy\s+3 came\s+3 stayed/, rehearsal)
    assert_match(/Every table matches/, rehearsal)
    assert_match(/^Refers to: agents \d+ instructions, email omar@example.com$/, rehearsal)
    assert_match(/^Threads: 2 start afresh: the copy holds no sidecar store/, rehearsal)
    assert_match(/Rehearsal: nothing was kept/, rehearsal)
    assert_equal before, [ Workspace.count, Agent.count, ActiveStorage::Blob.count ]

    output = task.(SOURCE: @directory, SOURCE_KEYS: keys, OWNER: "maya@example.com", NAME: "Old office", REHEARSE: nil)

    assert_match(/Imported as workspace \d+/, output)
    assert_equal before[1] + 2, Agent.count
    SOURCE_KEYS.each_value { assert_no_match(/#{it}/, rehearsal + output) }
    assert_no_match(/made-up-crm-token|made-up-passphrase/, rehearsal + output)
  end

  test "a second run of the same install is refused, and nothing is written" do
    build_install
    keys = Workspace::Import::Keys.new(**SOURCE_KEYS)
    first = Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", name: "Old office")
    counts = [ Workspace.count, Agent.count, Message.count, ActiveStorage::Blob.count ]

    error = assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", name: "Again") }

    assert_match(/already imported/, error.message)
    assert_match(/workspace #{first.workspace_id}/, error.message)
    assert_equal counts, [ Workspace.count, Agent.count, Message.count, ActiveStorage::Blob.count ]
  end

  test "an agent address already taken here refuses the whole import" do
    build_install
    @maya.personal_workspace.agents.create!(user: @maya, name: "Here", instructions: "Hi.", model: Agent.models.first, email_name: "scout-there")

    error = assert_no_difference -> { Workspace.count } do
      assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office") }
    end

    assert_match(/scout-there/, error.message)
  end

  test "the wrong keys refuse it, naming the column, and nothing is written" do
    build_install
    wrong = Workspace::Import::Keys.new(primary_key: "not-the-key", key_derivation_salt: "not-the-salt")

    error = assert_no_difference [ -> { Workspace.count }, -> { Agent.count } ] do
      assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys: wrong, owner: "maya@example.com", name: "Old office") }
    end

    assert_match(/agents\.passbolt_passphrase/, error.message)
  end

  test "keys derived from the other install's secret_key_base read what it encrypted" do
    workspace = @maya.personal_workspace
    connector = workspace.mcp_servers.create!(user: @maya, name: "crm", url: "https://crm.example.com/mcp", token: "made-up-token")
    ciphertext = McpServer.connection.select_value("SELECT token FROM mcp_servers WHERE id = #{connector.id}")

    assert_equal "made-up-token", Workspace::Import::Keys.new(secret_key_base: Rails.application.secret_key_base).decrypt(ciphertext)
    credentials = File.join(@directory, "credentials.yml").tap { File.write(it, { "secret_key_base" => Rails.application.secret_key_base, "other" => "x" }.to_yaml) }
    assert_equal "made-up-token", Workspace::Import::Keys.load(credentials).decrypt(ciphertext)
    assert_raises(Workspace::Import::Refused) { Workspace::Import::Keys.new }
  end

  # A web or job process loads its models before Rails sets the key
  # generator's digest to SHA256 (after initialization); `bin/rails
  # workspaces:import` loads them after. Each is booted here as
  # config/initializers/active_record_encryption.rb boots it, from a
  # secret_key_base that is not this test process's.
  test "what the import task writes, the install's web and job processes read with their own keys alone, and the other install's keys do not" do
    build_install
    target = "made-up-target-secret-key-base-#{SecureRandom.hex(16)}"
    web, task = [ OpenSSL::Digest::SHA1, OpenSSL::Digest::SHA256 ].map { booted_keys(target, digest_at_boot: it) }

    import = ActiveRecord::Encryption.with_encryption_context(key_provider: task) do
      Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")
    end

    assert import.check.all?(&:matches?)
    sealed = [ Workspace::Import::People::TABLE, *Workspace::Import::Table.all ].flat_map do |table|
      table.model.encrypted_attributes.to_a.flat_map do |column|
        table.model.connection.select_rows("SELECT id, #{column} FROM #{table.name} WHERE #{column} IS NOT NULL").map { [ table.model, column, *it ] }
      end
    end
    assert_equal %w[ agents.caldav_password agents.passbolt_passphrase campfire_bots.bot_key concourse_agents.client_secret concourse_agents.push_token users.link_session ],
      sealed.map { "#{it[0].table_name}.#{it[1]}" }.sort
    ActiveRecord::Encryption.with_encryption_context(key_provider: web) do
      unreadable = sealed.filter_map do |model, column, id, _|
        model.find(id).public_send(column) && nil
      rescue ActiveRecord::Encryption::Errors::Decryption
        "#{model.table_name}.#{column}"
      end
      assert_empty unreadable, "with the web process's keys alone"
      assert_equal "made-up-passphrase", import.workspace.agents.find_by!(name: "Scout").passbolt_passphrase
    end
    source = Workspace::Import::Keys.new(**SOURCE_KEYS)
    sealed.each { |model, column, _, text| assert_raises(ActiveRecord::Encryption::Errors::Decryption, "#{model.table_name}.#{column}, with the other install's keys") { source.decrypt(text) } }
  end

  test "what a web process or a task sealed before keys were derived alike reads with the same secret_key_base, in an import and in the install itself" do
    secret = "made-up-secret-key-base-#{SecureRandom.hex(16)}"
    keys, ours = Workspace::Import::Keys.new(secret_key_base: secret), booted_keys(secret, digest_at_boot: OpenSSL::Digest::SHA256)

    { OpenSSL::Digest::SHA1 => "web", OpenSSL::Digest::SHA256 => "task" }.each do |digest, process|
      sealed = ActiveRecord::Encryption::Encryptor.new.encrypt("made-up-#{process}-secret", key_provider: ActiveRecord::Encryption::KeyProvider.new(earlier_key(secret, digest)))
      assert_equal "made-up-#{process}-secret", keys.decrypt(sealed), "the other install's #{process} process sealed it"
      assert_equal "made-up-#{process}-secret", ActiveRecord::Encryption::Encryptor.new.decrypt(sealed, key_provider: ours), "this install's #{process} process sealed it"
    end
    assert_equal earlier_key(secret, OpenSSL::Digest::SHA1).secret, ours.encryption_key.secret, "it seals as web and job processes always have"
  end

  test "people are matched by sign-in subject, and the owner must already sign in here" do
    build_install
    keys = Workspace::Import::Keys.new(**SOURCE_KEYS)

    error = assert_no_difference [ -> { Workspace.count }, -> { User.count } ] do
      assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys:, owner: "omar@example.com", name: "Old office") }
    end
    assert_match(/omar@example.com owns the import but does not sign in here/, error.message)

    User.create!(oidc_sub: "sub-somebody-else", email: "omar@example.com", name: "Not Omar")
    error = assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", name: "Old office") }
    assert_match(/omar@example.com is someone else here, who signs in another way/, error.message)
  end

  test "into a shared workspace here that the owner owns, refusing one they do not or a connector name it has" do
    build_install
    keys = Workspace::Import::Keys.new(**SOURCE_KEYS)
    office = Workspace.create!(name: "Office").tap { it.memberships.create!(user: @maya, role: "owner") }
    theirs = Workspace.create!(name: "Theirs").tap { it.memberships.create!(user: User.create!(oidc_sub: "sub-ines", email: "ines@example.com"), role: "owner") }

    error = assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", into: theirs) }
    assert_match(/maya@example.com does not own Theirs/i, error.message)
    assert_match(/a personal workspace/, assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", into: @maya.personal_workspace) }.message)
    office.mcp_servers.create!(user: @maya, name: "crm", url: "https://other-crm.example.com/mcp")
    error = assert_no_difference -> { Agent.count } do
      assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", into: office) }
    end
    assert_match(/connector crm is already in Office/, error.message)
    office.mcp_servers.destroy_all

    import = Workspace::Import.run!(source: @directory, keys:, owner: "maya@example.com", into: office)

    assert_equal office, import.workspace
    assert_equal "Office", office.reload.name
    assert_equal %w[ Ledger Scout ], office.agents.order(:name).pluck(:name)
    assert_equal({ @maya => "owner", User.find_by!(oidc_sub: "sub-omar") => "member" }, office.memberships.to_h { [ it.user, it.role ] })
    assert import.check.all?(&:matches?), import.check.reject(&:matches?).map(&:to_s).join("\n")
  end

  test "every Campfire room, address and email named in instructions, skills and notes is reported, never rewritten" do
    build_install

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")

    scout = import.workspace.agents.find_by!(name: "Scout")
    ledger = import.workspace.agents.find_by!(name: "Ledger")
    assert_equal "Find things. Post in https://chat.example.com/rooms/12 and mail omar@example.com.", scout.instructions
    references = import.report["references"].map { it.values_at("table", "id", "column", "kind", "value") }
    assert_includes references, [ "agents", scout.id, "instructions", "url", "https://chat.example.com/rooms/12" ]
    assert_includes references, [ "agents", scout.id, "instructions", "campfire room", "12" ]
    assert_includes references, [ "agents", scout.id, "instructions", "email", "omar@example.com" ]
    assert_includes references, [ "notes", scout.notes.sole.id, "body", "campfire room", "7" ]
    assert_includes references, [ "skills", scout.skills.sole.id, "body", "url", "https://wiki.example.com/research" ]
    assert_includes references, [ "campfire_bots", ledger.campfire_bot.id, "rooms", "campfire room", "3" ]
    assert_match %r{^Refers to: agents #{scout.id} instructions, url https://chat\.example\.com/rooms/12$}, import.summary
  end

  test "an agent that wants more tools than an agent can have comes in, and is sent no more than the limit (#116)" do
    build_install
    insert "mcp_servers", id: 7, user_id: 1, name: "big", url: "https://big.example.com/mcp", args: json([]), disabled_tools: json([]),
      tools: json((1..Agent::TOOL_LIMIT).map { { "name" => "tool_#{it}", "description" => "One of many", "inputSchema" => { "type" => "object" } } })
    insert "core_connectors", id: 3, agent_id: 1, mcp_server_id: 7
    @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")

    scout = import.workspace.agents.find_by!(name: "Scout")
    assert_operator scout.tool_count, :>, Agent::TOOL_LIMIT, "it wants more than the limit"
    sent = scout.tools(scout.default_connectors).map(&:tool_name)
    assert_operator sent.size, :<=, Agent::TOOL_LIMIT
    assert_not_empty scout.toolset(scout.default_connectors).last, "the rest are looked up"
  end

  test "each thread carries what the other sidecar held for it, with its computer's files, and carrying again changes nothing" do
    build_install
    store = build_store(41, 42)
    put "agent/computers/bot-1/41/notes.md", "# Notes\nOmar keeps the books.\n"
    put "agent/computers/bot-1/41/work/report.txt", "the bytes of a report"
    install_sidecar_settings
    asked = []
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return do |request|
      asked << JSON.parse(request.body)
      { status: 201, body: { id: 9_000_000 + asked.size, carried: 7 }.to_json }
    end

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")

    scout = import.workspace.agents.find_by!(name: "Scout")
    thread, branch = scout.conversation, scout.conversations.where.not(parent_id: nil).sole
    assert_equal [ [ @maya.id.to_s, scout.id.to_s, thread.request_id, { "store" => store, "conversationId" => 41 } ],
                   [ @maya.id.to_s, scout.id.to_s, branch.request_id, { "store" => store, "conversationId" => 42 } ] ],
      asked.map { it.values_at("actorId", "workspaceId", "requestId", "carry") }
    assert_equal [ "9000001", 7 ], [ thread.reload.durable_id, thread.last_entry_id ]
    assert_equal "9000002", branch.reload.durable_id
    assert_equal "# Notes\nOmar keeps the books.\n", File.read(File.join(scout.workdir, "9000001", "notes.md"))
    assert_equal "the bytes of a report", File.read(File.join(scout.workdir, "9000001", "work", "report.txt"))
    files = import.reload.report.dig("computer_files", thread.id.to_s)
    assert_equal [ [ "notes.md", Digest::SHA256.hexdigest("# Notes\nOmar keeps the books.\n"), 30 ], [ "work/report.txt", Digest::SHA256.hexdigest("the bytes of a report"), 21 ] ], files
    assert_equal [], import.verify_files, "every file here has the hash it had there"
    assert_match(/Threads: 2 carried from the other sidecar/, import.summary)
    assert_match(/Ledger's computer is an SSH host \(books.example.com\): its files stay there/, import.summary)

    import.carry!(Workspace::Import::Source.new(@directory))
    assert_equal 2, asked.size, "a carried thread is not asked for again"

    File.write(File.join(scout.workdir, "9000001", "notes.md"), "changed")
    assert_equal [ "#{thread.id}: notes.md" ], import.verify_files
  end

  test "a thread the sidecar could not take yet is carried by the next carry" do
    build_install
    build_store(41, 42)
    install_sidecar_settings
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 503, body: { category: "starting" }.to_json)

    import = Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")

    assert_equal [ nil, nil ], import.workspace.conversations.pluck(:durable_id)
    assert_match(/Threads: 2 not carried yet: run bin\/rails workspaces:carry/, import.summary)
    # The sidecar gives each new conversation its own id; two alike are refused
    # as a store from another moment (Conversation::Mismatch).
    made = 0
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return { { status: 201, body: { id: 9_000_100 + (made += 1), carried: 3 }.to_json } }
    import.carry!(Workspace::Import::Source.new(@directory))
    assert_equal %w[ 9000101 9000102 ], import.workspace.conversations.reload.order(:id).pluck(:durable_id)
    assert_match(/Threads: 2 carried from the other sidecar/, import.reload.summary)
  end

  # The other install's Sprites token is scoped to its prefix, this one's to
  # this one's: a Sprite named as it was there is refused here (#167).
  test "an imported Sprite computer is named as this install names its new agent's, and the report keeps the old name for its host" do
    build_install
    sprite_there "otheroffice-production-b1"
    build_store(41, 42)

    import = with_setting(:pi_durable, :sprite_prefix, "thisoffice") do
      Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")
    end

    scout, ledger = import.workspace.agents.find_by!(name: "Scout"), import.workspace.agents.find_by!(name: "Ledger")
    assert_equal "thisoffice-#{ENV.fetch("DEPLOYMENT_ENVIRONMENT", Rails.env)}-b#{scout.id}", scout.computer.name
    assert_carried "computers", 1, scout.computer, except: %w[ agent_id name ]
    assert_carried "computers", 2, ledger.computer, except: %w[ agent_id ]
    assert_equal "ledger", ledger.computer.name, "an SSH computer keeps its name"
    host_steps = import.summary.lines.grep(/\AOn its host: /)
    assert_includes host_steps.join, "Scout's computer is a Sprite: its files stay on the other install's Sprites (otheroffice-production-b1-c41, otheroffice-production-b1-c42)"
    assert_equal [], import.summary.lines.grep_v(/\AOn its host: /).grep(/otheroffice/), "the old name is only where its files are"
  end

  # The sidecar asks the Sprites bridge for `<the computer's name>-c<thread>`
  # (agent/computers.mjs, spriteName): the name it is sent is the one it asks for.
  test "the first tool call in an imported thread asks the Sprites bridge for this install's name, never the other's" do
    build_install
    @copy.execute("UPDATE agents SET paused_at = NULL WHERE id = 1") # so its message goes, rather than being held
    sprite_there "otheroffice-production-b1"
    build_store(41, 42)
    install_sidecar_settings
    carried = 0
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return { { status: 201, body: { id: 9_000_200 + (carried += 1), carried: 3 }.to_json } }
    import = with_setting(:pi_durable, :sprite_prefix, "thisoffice") do
      Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office")
    end
    thread = import.workspace.agents.find_by!(name: "Scout").conversation
    asked = []
    stub_request(:post, "#{SIDECAR}/v1/conversations/#{thread.durable_id}/submissions").to_return do |request|
      computer = JSON.parse(request.body).dig("definition", "computer")
      asked << "#{computer["name"]}-c#{thread.durable_id}"
      { status: 202, body: { id: 1 }.to_json }
    end

    thread.submit("Make a file on your computer.", request_id: "first-tool-call")

    assert_equal [ "thisoffice-#{ENV.fetch("DEPLOYMENT_ENVIRONMENT", Rails.env)}-b#{thread.agent_id}-c#{thread.durable_id}" ], asked
    assert asked.none? { it.start_with?("otheroffice") }
  end

  test "a sidecar store that does not hold every thread is not from the same moment, and is refused" do
    build_install
    build_store(41)

    error = assert_raises(Workspace::Import::Refused) { Workspace::Import.run!(source: @directory, keys: Workspace::Import::Keys.new(**SOURCE_KEYS), owner: "maya@example.com", name: "Old office") }

    assert_match(/agent-durable.sqlite does not hold 1 thread\(s\) the database names \(42\)/, error.message)
  end

  private
    def source_database = File.join(@directory, "production.sqlite3")

    def load_source_schema
      body = SCHEMA.read[/define\(version: \S+\) do\n(.*)^end/m, 1]
      Class.new(ActiveRecord::Migration[8.2]) { define_method(:change) { instance_eval(body) } }.new.tap do |schema|
        schema.verbose = false
        schema.exec_migration(@copy, :up)
      end
      @copy.execute("CREATE TABLE schema_migrations (version varchar NOT NULL PRIMARY KEY)")
      @copy.execute("INSERT INTO schema_migrations (version) VALUES ('20261115030000'), ('20261115040000')")
    end

    # A small, realistic install: two people, two agents, a thread with a
    # branch, its messages, a card and its approval, a file, notes, a
    # connector with an encrypted key, and an agent's mail and calendar
    # sign-in (at this release, its address and CalDAV account; the
    # agent_mail_accounts table came later).
    def build_install
      insert "users", id: 1, oidc_sub: "sub-maya", name: "Maya There", email: "Maya@Example.com", ssh_keyring: nil
      insert "users", id: 2, oidc_sub: "sub-omar", name: "Omar", email: "omar@example.com", ssh_keyring: "person-2", push_errors: false,
        link_session: encrypt({ "refresh_token" => "made-up-link-refresh" }.to_json)
      insert "agents", id: 2, user_id: 2, name: "Ledger", instructions: "Keep the books.", model: "made-up/model", email_name: "ledger-there",
        phone_number: "+15550100", tool_names: json(%w[ send_email ]), capabilities: json(%w[ codemode ]), disabled_tools: json([]), asks_every_text: true
      insert "agents", id: 1, user_id: 1, name: "Scout", instructions: "Find things. Post in https://chat.example.com/rooms/12 and mail omar@example.com.", model: "made-up/model", email_name: "scout-there",
        tool_names: json(%w[ send_email note_write ]), capabilities: json(%w[ codemode web_search ]), disabled_tools: json(%w[ sms ]),
        title: "Researcher", passbolt_passphrase: encrypt("made-up-passphrase"), caldav_username: "scout", caldav_password: encrypt("made-up-caldav-password"),
        mail_to_agent_id: 2, linked_calendar_server: "https://calendar.example.com/family/", linked_calendar: "shared", linked_calendar_entry: "Family calendar",
        paused_at: NOW
      insert "agent_revisions", id: 1, agent_id: 1, instructions: "Find things.", model: "made-up/model", tool_names: json(%w[ send_email ]),
        capabilities: json([]), skills: json(%w[ research ]), prompts: json([])
      insert "notes", id: 1, agent_id: 1, key: "people", body: "Omar keeps the books. Ask in room 7."
      insert "prompts", id: 1, agent_id: 1, name: "weekly", description: "The weekly summary", body: "Summarise the week."
      insert "skills", id: 1, agent_id: 1, name: "research", description: "How to research", body: "Read widely; see https://wiki.example.com/research.", github_repo: "example/skills"
      insert "skill_bundled_files", id: 1, skill_id: 1, path: "scripts/find.sh", content: "#!/bin/sh\necho found\n".b, size: 21, executable: true
      insert "documents", id: 1, agent_id: 1, title: "Plan", kind: "markdown", seen_version_id: 1
      insert "document_versions", id: 1, document_id: 1, number: 1, body: "# Plan", author: "agent"
      insert "routines", id: 1, agent_id: 1, schedule: "every weekday at 9am", prompt: "Check the mail.", next_run_at: NOW + 1.day
      insert "permissions", id: 1, agent_id: 1, tool_name: "send_email", recipient: "omar@example.com", granted_by_id: 2
      insert "computers", id: 1, agent_id: 1, provider: "local", name: "scout", state: "on", folder: nil
      insert "computers", id: 2, agent_id: 2, provider: "ssh", name: "ledger", state: "off", ssh_host: "books.example.com", ssh_user: "ledger", folder: "/srv/books"
      insert "concourse_agents", id: 1, agent_id: 1, organization: "example-org", handle: "scout", client_id: "made-up-client-id",
        client_secret: encrypt("made-up-client-secret"), push_token: encrypt("made-up-push-token"), cursor: "c-41"
      insert "campfire_bots", id: 1, agent_id: 2, askers: json({ "9" => "omar" }), bot_key: encrypt("7-madeupbotkey"), token: "madeuptokenmadeuptokenmadeuptokn",
        rooms: json({ "3" => "Books" }), confirmed_at: NOW
      insert "conversations", id: 1, user_id: 1, agent_id: 1, request_id: "req-root", durable_id: "41", title: "", status: "idle",
        last_entry_id: 1012, usage: json({ "input" => 10 }), listed_at: NOW, last_message_at: NOW, activated_tools: json([])
      insert "conversations", id: 2, user_id: 1, agent_id: 1, request_id: "req-branch", durable_id: "42", title: "A branch", parent_id: 1, root_id: 1,
        forked_at_entry_id: 1010, listed_at: NOW, activated_tools: json([])
      insert "mcp_servers", id: 1, user_id: 1, name: "crm", url: "https://crm.example.com/mcp", token: encrypt("made-up-crm-token"),
        headers: encrypt({ "X-Account" => "made-up-account" }.to_json), tools: json([ { "name" => "find" } ]), args: json([]), disabled_tools: json([])
      insert "mcp_servers", id: 2, user_id: 1, name: "wiki", url: "https://wiki.example.com/mcp", install: "wiki", tools: json([]), args: json([]), disabled_tools: json([])
      insert "mcp_servers", id: 3, user_id: 1, conversation_id: 1, name: "notes", url: "https://notes.example.com/mcp", token: encrypt("made-up-notes-token"),
        tools: json([]), args: json([]), disabled_tools: json([])
      insert "mcp_servers", id: 4, user_id: 2, name: "books", url: "https://books.example.com/mcp", token: encrypt("made-up-books-token"),
        tools: json([]), args: json([]), disabled_tools: json([])
      insert "mcp_servers", id: 5, user_id: 1, name: "old", url: "https://old.example.com/mcp", enabled: false, tools: json([]), args: json([]), disabled_tools: json([])
      insert "mcp_servers", id: 6, user_id: 1, name: "gmail", url: "https://gmail.example.com/mcp", oauth_app: "google", oauth_scope: "mail.read",
        oauth_tokens: encrypt({ "access_token" => "made-up-access", "refresh_token" => "made-up-refresh" }.to_json), tools: json([]), args: json([]), disabled_tools: json([])
      insert "core_connectors", id: 1, agent_id: 1, mcp_server_id: 1
      insert "core_connectors", id: 2, agent_id: 1, mcp_server_id: 2
      insert "messages", id: 1, conversation_id: 1, entry_key: "1010", entry_id: 1010, role: "user", content: "Hello Scout", tool_calls: json([])
      insert "messages", id: 2, conversation_id: 1, entry_key: "1012", entry_id: 1012, role: "assistant", content: "Hello Maya",
        tool_calls: json([]), usage: json({ "output" => 3 }), thinking: "A greeting."
      insert "invocations", id: 1, conversation_id: 1, task_id: "t1", call_id: "c1", tool_name: "send_email",
        arguments: json({ "to" => "omar@example.com" }), digest: "d1", state: "done", result: json({ "sent" => true })
      insert "approvals", id: 1, invocation_id: 1, decided_by_id: 1, decision: "approved"
      insert "uploads", id: 1, conversation_id: 1, task_id: "t1", call_id: "c1", path: "/work/report.txt", sha256: "made-up-sha"
      insert "peer_tasks", id: 1, conversation_id: 1, task_id: "task-1", peer: "example-org/helper", direction: "outgoing", state: "working",
        delivered_ids: json([ "m1" ]), concourse_agent_id: 1
      attach "Message", 1, "images", "whiteboard.png", "image/png", "a picture of the whiteboard"
      attach "Upload", 1, "file", "report.txt", "text/plain", "the bytes of a report"
      @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    end

    # The key a release before the fix sealed with: derived through
    # Rails.application.key_generator, built with whichever digest Active
    # Support had when the process first asked for it.
    def earlier_key(secret_key_base, digest)
      generator = ActiveSupport::KeyGenerator.new(secret_key_base, iterations: 1000, hash_digest_class: digest)
      primary_key, salt = %w[ primary_key salt ].map { generator.generate_key("active_record_encryption/#{it}", 32).unpack1("H*") }
      ActiveRecord::Encryption::Key.new(ActiveSupport::KeyGenerator.new(primary_key, hash_digest_class: OpenSSL::Digest::SHA256).generate_key(salt, 32))
    end

    # The keys a process encrypts with, booted from this secret_key_base by
    # config/initializers/active_record_encryption.rb while Active Support's
    # key generator digest is the one given; this process's are put back.
    def booted_keys(secret_key_base, digest_at_boot:)
      config, generators = ActiveRecord::Encryption.config, Rails.application.instance_variable_get(:@key_generators)
      saved = [ ActiveSupport::KeyGenerator.hash_digest_class, Rails.application.config.secret_key_base, config.primary_key, config.key_derivation_salt, ActiveRecord::Encryption.default_context ]
      ActiveSupport::KeyGenerator.hash_digest_class = digest_at_boot
      Rails.application.config.secret_key_base = secret_key_base
      generators.delete(secret_key_base)
      config.primary_key = nil
      load Rails.root.join("config/initializers/active_record_encryption.rb").to_s
      ActiveRecord::Encryption.key_provider
    ensure
      ActiveSupport::KeyGenerator.hash_digest_class, Rails.application.config.secret_key_base = saved[0], saved[1]
      config.primary_key, config.key_derivation_salt = saved[2], saved[3]
      ActiveRecord::Encryption.default_context = saved[4]
      generators.delete(secret_key_base)
    end

    # The other install's sidecar store, as its backup set names it: here only
    # the threads it holds matter, which Rails reads; the sidecar reads the rest.
    def build_store(*ids)
      path = File.join(@directory, "agent-durable.sqlite")
      SQLite3::Database.new(path) do |db|
        db.execute("CREATE TABLE conversations (id INTEGER PRIMARY KEY, owner_conversation_id INTEGER, owner_task_id INTEGER, record TEXT NOT NULL)")
        ids.each { db.execute("INSERT INTO conversations (id, record) VALUES (?, '{}')", [ it ]) }
      end
      path
    end

    # Scout's computer a Sprite, named as the other install named it.
    def sprite_there(name)
      @copy.execute("UPDATE computers SET provider = 'sprites', name = #{@copy.quote(name)} WHERE id = 1")
      @copy.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    end

    def put(path, content)
      path = File.join(@directory, path)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def insert(table, **attributes)
      attributes = { created_at: NOW, updated_at: NOW }.merge(attributes).slice(*@copy.columns(table).map(&:name).map(&:to_sym))
      values = attributes.values.map { it.is_a?(String) && it.encoding == Encoding::BINARY ? "x'#{it.unpack1("H*")}'" : @copy.quote(it) }
      @copy.execute("INSERT INTO #{table} (#{attributes.keys.map { @copy.quote_column_name(it) }.join(", ")}) VALUES (#{values.join(", ")})")
    end

    def attach(record_type, record_id, name, filename, content_type, bytes)
      @blobs = (@blobs || 0) + 1
      key = "madeupkey#{@blobs}#{"x" * 20}"
      path = File.join(@directory, key[0..1], key[2..3], key)
      FileUtils.mkdir_p(File.dirname(path))
      File.binwrite(path, bytes)
      insert "active_storage_blobs", id: @blobs, key:, filename:, content_type:, metadata: json({ "identified" => true }), service_name: "local",
        byte_size: bytes.bytesize, checksum: OpenSSL::Digest::MD5.base64digest(bytes)
      insert "active_storage_attachments", id: @blobs, name:, record_type:, record_id:, blob_id: @blobs
    end

    def json(value) = value.to_json

    # The copy upgraded by this release's own migrations, as its install would have been.
    def migrate_source
      Dir[Rails.root.join("db/migrate/*.rb")].sort_by { File.basename(it).to_i }.each do |file|
        version, name = File.basename(file, ".rb").match(/\A(\d+)_(.+)\z/).captures
        next unless yield version.to_i
        class_name = name.camelize
        Object.send(:remove_const, class_name) if Object.const_defined?(class_name)
        load file
        migration = class_name.constantize.new(class_name, version.to_i)
        migration.verbose = false
        @copy.transaction { migration.exec_migration(@copy, :up) }
        @copy.execute("INSERT INTO schema_migrations (version) VALUES ('#{version}')")
      end
    end

    # As the other install's Active Record would have written it, under its own keys.
    def encrypt(text)
      key = ActiveSupport::KeyGenerator.new(SOURCE_KEYS[:primary_key], hash_digest_class: ActiveRecord::Encryption.config.hash_digest_class)
        .generate_key(SOURCE_KEYS[:key_derivation_salt], ActiveRecord::Encryption.cipher.key_length)
      ActiveRecord::Encryption::Encryptor.new.encrypt(text, key_provider: ActiveRecord::Encryption::KeyProvider.new(ActiveRecord::Encryption::Key.new(key)))
    end

    # Every column the release here shares with the other, but those named,
    # holds the same value as stored there.
    def assert_carried(table, source_id, record, except: [])
      source = @copy.select_one("SELECT * FROM #{table} WHERE id = #{source_id}")
      target = record.class.connection.select_one("SELECT * FROM #{table} WHERE id = #{record.id}")
      columns = source.keys & target.keys - %w[ id ] - except
      assert_equal source.slice(*columns), target.slice(*columns), "#{table} #{source_id}"
    end
end
